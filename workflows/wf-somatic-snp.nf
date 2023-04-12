
include {
    getParams;
    getVersions;
    vcfStats;
    makeReport;
    output_snp;
    clairs_select_het_snps;
    clairs_phase;
    clairs_haplotag;
    wf_build_regions;
    clairs_extract_candidates;
    clairs_create_paired_tensors;
    clairs_predict_pileup;
    clairs_merge_pileup;
    clairs_create_fullalignment_paired_tensors;
    clairs_predict_full;
    clairs_merge_full;
    clairs_full_hap_filter;  
    clairs_merge_final;
    clairs_create_paired_tensors_indels;
    clairs_predict_pileup_indel;
    clairs_merge_pileup_indels;
    clairs_create_fullalignment_paired_tensors_indels;
    clairs_predict_full_indels;
    clairs_merge_full_indels;
    clairs_merge_final_indels;
    clairs_merge_snv_and_indels;
    annotate_spectra
} from "../modules/local/wf-somatic-snp.nf"

include {
    make_chunks;
    pileup_variants;
    aggregate_pileup_variants;
    select_het_snps;
    phase_contig;
    get_qual_filter;
    create_candidates;
    evaluate_candidates;
    aggregate_full_align_variants;
    merge_pileup_and_full_vars;
    aggregate_all_variants;
} from "../modules/local/wf-clair3-snp.nf"

// workflow module
workflow snp {
    take:
        bam_channel
        bed
        ref
        clairs_model
        clair3_model
    main:
        // Branch cancer and control for downstream works
        bam_channel.branch{
            cancer: it[2].type == 'cancer'
            control: it[2].type == 'control'
        }.set{forked_channel}        

        // Initialize contigs and intervals for each pair of tumor/normal bam files
        forked_channel.control
            .map{ bam, bai, meta -> [ meta.sample, bam, bai, meta ] } 
            .cross(
                forked_channel.cancer.map{ bam, bai, meta -> [ meta.sample, bam, bai, meta ] }
            )
            .map { control, cancer ->
                    [control[1], control[2], cancer[1], cancer[2], cancer[3]]
                } 
            .map{ it -> it.flatten() }
            .set{paired_samples}
        wf_build_regions( paired_samples, ref.collect(), clairs_model, bed )

        // Extract contigs to feed into make_chunks to keep consistent parameters
        clair3_input_ctgs = wf_build_regions.out.contigs_file.map() { it -> [it[0].sample, it[1]] }

        /* =============================================== */
        /* Run Clair3 functions on each bam independently. */
        /* =============================================== */

        // Prepare the bam channel for the chunking.
        bam_channel.map{bam, bai, meta -> [meta.sample, bam, bai, meta]}
            .combine(clair3_input_ctgs, by: 0)
            .map{
                sample, bam, bai, meta, ctgs -> [meta, bam, bai, ctgs]
            }
            .combine(ref)
            .combine(bed)
            .set{bams}

        // Prepare the chunks for each bam file.
        make_chunks(bams)
        chunks = make_chunks.out.chunks_file
            .splitText(){ 
                cols = (it[1] =~ /(.+)\s(.+)\s(.+)/)[0]
                [it[0], ["contig": cols[1], "chunk_id":cols[2], "total_chunks":cols[3]]]
                } 
        contigs = make_chunks.out.contigs_file.splitText() { it -> [it[0], it[1].trim()] }

        // Run the "pileup" caller on all chunks and collate results
        // > Step 1 
        bam_channel
            .combine(ref)
            .combine(bed)
            .map{bam, bai, meta, ref, fai, ref_cache, bed ->
                [meta, bam, bai, ref, fai, ref_cache, bed]
            }
            .combine(chunks, by:0)
            .combine(clair3_model)
            .set{fragments}
        pileup_variants(fragments)

        // Aggregate outputs
        // Clairs model is required to define the correct var_pct_phasing 
        // value (0.7 for r9, 0.8 for r10).
        pileup_variants.out.pileup_vcf_chunks
            .groupTuple(by: 0)
            .combine(ref)
            .combine(
                make_chunks.out.contigs_file, by: 0
            )
            .combine(
                clair3_model
            ) .set{pileup_vcfs}
        aggregate_pileup_variants(pileup_vcfs)

        // Filter collated results to produce per-contig SNPs for phasing.
        // > Step 2
        aggregate_pileup_variants.out.pileup_vcf
            .combine(aggregate_pileup_variants.out.phase_qual, by: 0)
            .combine(contigs, by: 0)
            .set{ aggregated_pileup_vcf }
        select_het_snps(aggregated_pileup_vcf)
        // Perform phasing for each contig.
        // Combine the het variants with the input bam channels 
        // using the metadata as joining criteria (by:2), and then add 
        // the reference channel.
        // Then run the phasing
        phase_inputs = select_het_snps.out.het_snps_vcf
            .combine(bam_channel, by: 2)
            .combine(ref)
        phase_contig(phase_inputs)
        phase_contig.out.phased_bam_and_vcf.set { phased_bam_and_vcf }

        // Find quality filter to select variants for "full alignment"
        // processing, then generate bed files containing the candidates.
        // > Step 5
        get_qual_filter(aggregate_pileup_variants.out.pileup_vcf)
        aggregate_pileup_variants.out.pileup_vcf
            .combine(ref)
            .combine(get_qual_filter.out.full_qual, by: 0)
            .combine(contigs, by: 0)
            .set{pileup_and_qual}
        create_candidates(pileup_and_qual)

        // Run the "full alignment" network on candidates. Have to go through a
        // bit of a song and dance here to generate our input channels here
        // with various things duplicated (again because of limitations on 
        // `each` and tuples).
        // > Step 6
        create_candidates.out.candidate_bed.flatMap {
            x ->
                // output globs can return a list or single item
                y = x[2]; if(! (y instanceof java.util.ArrayList)){y = [y]}
                // effectively duplicate chr for all beds - [chr, bed]
                y.collect { [[x[0], x[1]], it] } }
                .set{candidate_beds}
        // produce something emitting: [[chr, bam, bai, vcf], [chr20, bed], [ref, fai, cache], model]
        bams_beds_and_stuff = phased_bam_and_vcf
            .map{meta, ctg, bam, bai, vcf, tbi -> [ [meta, ctg], bam, bai, vcf, tbi ]}
            .cross(candidate_beds)
            .combine(ref.map {it->[it]})
            .combine(clair3_model)
        // take the above and destructure it for easy reading
        bams_beds_and_stuff.multiMap {
            it ->
                bams: it[0].flatten()
                candidates: it[1].flatten()
                ref: it[2]
                model: it[3]
            }.set { mangled }
        // phew! Run all-the-things
        evaluate_candidates(mangled.bams, mangled.candidates, mangled.ref, mangled.model)

        // merge and sort all files for all chunks for all contigs
        // gvcf is optional, stuff an empty file in, so we have at least one
        // item to flatten/collect and tthis stage can run.
        evaluate_candidates.out.full_alignment.groupTuple(by: 0)
            .combine(ref)
            .combine(make_chunks.out.contigs_file, by:0)
            .set{to_aggregate}
        aggregate_full_align_variants(to_aggregate)

        // merge "pileup" and "full alignment" variants, per contig
        // note: we never create per-contig VCFs, so this process
        //       take the whole genome VCFs and the list of contigs
        //       to produce per-contig VCFs which are then finally
        //       merge to yield the whole genome results.

        // First merge whole-genome results from pileup and full_alignment
        //   for each contig...
        // note: the candidate beds aren't actually used by the program for ONT
        // > Step 7
        aggregate_pileup_variants.out.pileup_vcf
            .combine(aggregate_full_align_variants.out.full_aln_vcf, by: 0)
            .combine(ref)
            .combine( candidate_beds
                        .map { it->[it[0][0], it[1]] }
                        .groupTuple(by:0), by:0 )
            .combine(contigs, by:0)
            .set{to_aggregate_pileup_and_full}
        merge_pileup_and_full_vars(to_aggregate_pileup_and_full)

        // Finally, aggregate full variants for each sample
        merge_pileup_and_full_vars.out.merged_vcf
            .groupTuple(by:0)
            .combine(Channel.fromPath("$projectDir/data/OPTIONAL_FILE"))
            .combine(ref)
            .combine(make_chunks.out.contigs_file, by: 0)
            .set{final_vcfs}
        aggregate_all_variants( final_vcfs )

        // Before proceeding to ClairS, we need to prepare the appropriate 
        // matched VCFs for tumor/normal pairs.
        // First, we branch based on whether they are tumor or normal:
        aggregate_all_variants.out.final_vcf
            .branch{
                cancer: it[0].type == 'cancer'
                control: it[0].type == 'control'
            }.set{forked_vcfs}

        // Then we can combine cancer and control for the same sample.
        forked_vcfs.control
            .map{ meta, vcf, tbi -> [ meta.sample, vcf, tbi, meta ] } 
            .cross(
                forked_vcfs.cancer.map{ meta, vcf, tbi -> [ meta.sample, vcf, tbi, meta ] }
            )
            .map { control, cancer ->
                    [cancer[3], cancer[1], cancer[2], control[3], control[1], control[2], ]
                } 
            .map{ it -> it.flatten() }
            .set{paired_vcfs}

        /* ============================================ */
        /* Run ClairS functions from here on.           */
        /* The workflow will run partly in parallel     */
        /* with Clair3, and finishing off when Clair3   */
        /* completes the germline calling.              */
        /* ============================================ */

        /*
        /  Running the pileup model.
        */
        // Combine the channels of each chunk, with the pair of
        // bams and the all the bed for each sample
         wf_build_regions.out.chunks_file
                .splitText(){
                        cols = (it[1] =~ /(.+)\s(.+)\s(.+)/)[0]
                        region_map = ["contig": cols[1], "chunk_id":cols[2], "total_chunks":cols[3]]
                        [it[0], region_map]
                    }
                .combine(
                    paired_samples
                        .map{
                            ctrbm, ctrbi, canbm, canbi, meta -> [meta, ctrbm, ctrbi, canbm, canbi]
                            }, by: 0
                    )
                .combine(wf_build_regions.out.split_beds, by: 0)
                .combine(ref)
                .combine(clairs_model)
                .set{chunks}
        clairs_contigs = wf_build_regions.out.contigs_file.splitText() { it -> [it[0], it[1].trim()] }

        // Extract candidates for the tensor generation.
        clairs_extract_candidates(chunks)
        // Separate InDels and SNVs candidates
        clairs_extract_candidates.out.candidates_snvs

        // Prepare the paired tensors for each tumor/normal pair.
        clairs_create_paired_tensors(chunks.combine(clairs_extract_candidates.out.candidates_snvs, by: [0,1]))
        
        // Predict variants based on the paired pileup model
        clairs_predict_pileup(clairs_create_paired_tensors.out)

        // Combine all predicted pileup vcf into one pileup.vcf file.
        clairs_predict_pileup.out
            .groupTuple(by:0)
            .combine(wf_build_regions.out.contigs_file, by: 0)
            .set{collected_vcfs}
        clairs_merge_pileup(collected_vcfs, ref.collect())

        /*
        /  Processing the full alignments
        */
        // Extract the germline heterozygote sites using both normal and cancer
        // VCF files
        clairs_select_het_snps(paired_vcfs.combine(clairs_contigs, by: 0))

        // Prepare the input channel for the phasing (cancer or cancer+normal if requested).
        if (params.phase_normal){
            clairs_select_het_snps.out.control_hets
                .combine(forked_channel.control
                            .map {bam, bai, meta -> [meta, bam, bai]}, by: 0
                            )
                .combine(ref)
                .mix(
                    clairs_select_het_snps.out.cancer_hets
                        .combine(forked_channel.cancer
                                    .map {bam, bai, meta -> [meta, bam, bai]}, by: 0
                                    )
                        .combine(ref)
                )
                .set { het_to_phase }
        } else {
            clairs_select_het_snps.out.cancer_hets
                .combine(forked_channel.cancer
                            .map {bam, bai, meta -> [meta, bam, bai]}, by: 0
                            )
                .combine(ref)
                .set { het_to_phase }
        }

        // Phase and haplotag the selected vcf and bams (cancer-only or both).
        het_to_phase | clairs_phase | clairs_haplotag

        // Prepare the channel for the tensor generation.
        // If phase normal is specified, then combine the phased VCF files 
        // for both the cancer and the normal haplotagged samples...
        if (params.phase_normal){
            clairs_haplotag.out.phased_data
                .branch{
                    cancer: it[4].type == 'cancer'
                    control: it[4].type == 'control'
                }.set{f_phased_channel}
            f_phased_channel.cancer
                .combine(f_phased_channel.control, by: [0,1])
                .map{sample, contig, tbam, tbai, tmeta, nbam, nbai, nmeta -> 
                        [sample, contig, tbam, tbai, tmeta, nbam, nbai]
                }
                .combine(
                    clairs_extract_candidates.out.candidates_snvs.map{it -> [it[0].sample, it[1].contig, it[3]]}, by: [0,1] )
                .combine(ref)
                .combine(clairs_model)
                .set{ paired_phased_channel }
        // ...otherwise keep only the cancer haplotagged bam files.
        } else {
            clairs_haplotag.out.phased_data
                .combine(forked_channel.control.map{it -> [it[2].sample, it[0], it[1]]}, by: 0)
                .combine(
                    clairs_extract_candidates.out.candidates_snvs.map{it -> [it[0].sample, it[1].contig, it[3]]}, by: [0,1] )
                .combine(ref)
                .combine(clairs_model)
                .set{paired_phased_channel}
        }

        // Create the full-alignment tensors
        clairs_create_fullalignment_paired_tensors(paired_phased_channel)

        // Prediction of variant on full-alignments
        clairs_predict_full(clairs_create_fullalignment_paired_tensors.out.full_tensors)

        // Combine the full-alignment somatic SNV VCF
        clairs_predict_full.out.full_vcfs
            .groupTuple(by:0)
            .combine(wf_build_regions.out.contigs_file, by: 0)
            .combine(ref)
            .set{collected_full_vcfs}
        clairs_merge_full(collected_full_vcfs)

        // Almost there!!!
        //
        // Perform the haplotype-based filtering. This step can either be:
        //  1. By contig: very fast and resource efficient, but does not provide 
        //     the same results as ClairS.
        //  2. Full vcf: very slow and less resource efficient, but provide 
        //     results identical to ClairS.
        //
        // If split haplotype filter is specified, run by contig:
        if (params.skip_haplotype_filter){
            clairs_merge_pileup.out.pileup_vcf
                .combine(
                    clairs_merge_full.out.full_vcf, by:0
                )
                .combine( ref )
                .set{ clair_all_variants }
            clair_all_variants | clairs_merge_final
        } else {
            // Create channel with the cancer bam, all the VCFs
            // (germline, pileup and full-alignment) and the 
            // reference genome.
            clairs_haplotag.out.phased_data
                .map{ samp, ctg, bam, bai, meta -> [meta, bam, bai] }
                .groupTuple(by: 0)
                .combine(
                    aggregate_all_variants.out.final_vcf, by: 0
                )
                .combine(
                    clairs_merge_pileup.out.pileup_vcf, by: 0
                )
                .combine(
                    clairs_merge_full.out.full_vcf, by:0
                )
                .combine( ref )
                .set{ clair_all_variants }
            // Apply the filtering and create the final VCF.
            clair_all_variants | clairs_full_hap_filter | clairs_merge_final
        }

        // Perform indel calling if the model is appropriate
        if (params.basecaller_cfg.startsWith('dna_r10')){
            // Create paired tensors for the indels candidates
            clairs_create_paired_tensors_indels(chunks.combine(clairs_extract_candidates.out.candidates_indels, by: [0,1]))

            // Create paired tensors for the indels candidates
            clairs_predict_pileup_indel( clairs_create_paired_tensors_indels.out )

            // Merge and sort all the pileup indels
            clairs_predict_pileup_indel.out
                .groupTuple(by:0)
                .combine(wf_build_regions.out.contigs_file, by: 0)
                .set{collected_indels}
            clairs_merge_pileup_indels(collected_indels, ref.collect())

            // Create the full alignment indel paired tensors
            if (params.phase_normal){
                clairs_haplotag.out.phased_data
                    .branch{
                        cancer: it[4].type == 'cancer'
                        control: it[4].type == 'control'
                    }.set{f_phased_channel}
                f_phased_channel.cancer
                    .combine(f_phased_channel.control, by: [0,1])
                    .map{sample, contig, tbam, tbai, tmeta, nbam, nbai, nmeta -> 
                            [sample, contig, tbam, tbai, tmeta, nbam, nbai]
                    }
                    .combine(
                        clairs_extract_candidates.out.candidates_indels.map{it -> [it[0].sample, it[1].contig, it[3]]}, by: [0,1] )
                    .combine(ref)
                    .combine(clairs_model)
                    .set{ paired_phased_indels_channel }
            // ...otherwise keep only the cancer haplotagged bam files.
            } else {
                clairs_haplotag.out.phased_data
                    .combine(forked_channel.control.map{it -> [it[2].sample, it[0], it[1]]}, by: 0)
                    .combine(
                        clairs_extract_candidates.out.candidates_indels.map{it -> [it[0].sample, it[1].contig, it[3]]}, by: [0,1] )
                    .combine(ref)
                    .combine(clairs_model)
                    .set{paired_phased_indels_channel}
            }
            clairs_create_fullalignment_paired_tensors_indels( paired_phased_indels_channel )

            // Predict full alignment indels
            clairs_predict_full_indels(clairs_create_fullalignment_paired_tensors_indels.out.full_tensors)

            // Merge full alignment indels
            clairs_predict_full_indels.out.full_vcfs
                .groupTuple(by:0)
                .combine(wf_build_regions.out.contigs_file, by: 0)
                .combine(ref)
                .set{collected_full_vcfs}
            clairs_merge_full_indels( collected_full_vcfs )

            // Merge final indel file
            clairs_merge_pileup_indels.out.pileup_vcf
                .combine( clairs_merge_full_indels.out.full_vcf, by: 0 )
                .combine(ref)
                .set { merged_indels_vcf }
            clairs_merge_final_indels(merged_indels_vcf)

            // Create final two VCFs
            clairs_merge_final.out.pileup_vcf
                .combine(clairs_merge_final.out.pileup_tbi, by: 0 )
                .combine(clairs_merge_final_indels.out.indel_vcf, by: 0 )
                .combine(clairs_merge_final_indels.out.indel_tbi, by: 0 )
                .set { snv_and_indels }
            clairs_merge_snv_and_indels( snv_and_indels )
            pileup_vcf = clairs_merge_snv_and_indels.out.pileup_vcf
            pileup_tbi = clairs_merge_snv_and_indels.out.pileup_tbi
        } else {
            pileup_vcf = clairs_merge_final.out.pileup_vcf
            pileup_tbi = clairs_merge_final.out.pileup_tbi
        }

        // Annotate the mutation type in the format XX[N>N]XX
        // where XX are the flanking regions of a given size 
        // For now, only K = 3 is provided.
        pileup_vcf
            .combine(pileup_tbi, by: 0)
            .combine(ref)
            .set{clairs_vcf}
        annotate_spectra(clairs_vcf)
        ch_vcf = annotate_spectra.out.mutype_vcf
        ch_tbi = annotate_spectra.out.mutype_tbi

        // Generate basic statistics for the VCF file
        vcfStats(ch_vcf, ch_tbi)

        // Create the report for the variants called
        software_versions = getVersions()
        workflow_params = getParams()
        ch_vcf
            .combine(ch_tbi, by: 0)
            .combine(vcfStats.out[0], by: 0)
            .combine(annotate_spectra.out.spectrum, by: 0)
            .combine(software_versions.collect())
            .combine(workflow_params)
            .set{ reporting }
        makeReport(reporting)

        // Create a single channel with all the outputs and the respective path
        ch_vcf
            .map{ 
                meta, vcf -> [ vcf, "snp/${meta.sample}/vcf" ]
                }
            .concat(
                ch_tbi.map{
                    meta, txt -> [txt, "snp/${meta.sample}/vcf"]
                    })
            .concat(
                forked_vcfs.cancer.map{
                    meta, vcf, tbi -> [vcf, "snp/${meta.sample}/vcf/germline/cancer"]
                    })
            .concat(
                forked_vcfs.cancer.map{
                    meta, vcf, tbi -> [tbi, "snp/${meta.sample}/vcf/germline/cancer"]
                    })
            .concat(
                forked_vcfs.control.map{
                    meta, vcf, tbi -> [vcf, "snp/${meta.sample}/vcf/germline/control"]
                    })
            .concat(
                forked_vcfs.control.map{
                    meta, vcf, tbi -> [tbi, "snp/${meta.sample}/vcf/germline/control"]
                    })
            .concat(
                vcfStats.out.map{
                    meta, stats -> [stats, "snp/${meta.sample}/varstats"]
                    })
            .concat(
                annotate_spectra.out.spectrum.map{
                    meta, spectra -> [spectra, "snp/${meta.sample}/spectra"]
                    })
            .concat(
                workflow_params.map{
                    params -> [params, "snp/info"]
                    })
            .concat(
                software_versions.map{
                    versions -> [versions, "snp/info"]
                    })
            .concat(
                makeReport.out.html.map{
                    it -> [it, "snp/reports/"]
                })
            .concat(
                clairs_merge_final.out.pileup_vcf.map{meta, vcf -> [vcf, "snp/${meta.sample}/vcf/snv"]}
                )
            .concat(
                clairs_merge_final.out.pileup_tbi.map{meta, tbi -> [tbi, "snp/${meta.sample}/vcf/snv"]}
                )
            .set{tmp_outputs}
        if (params.basecaller_cfg.startsWith('dna_r10')){
            tmp_outputs
                .concat(
                    clairs_merge_final_indels.out.indel_vcf.map{meta, vcf -> [vcf, "snp/${meta.sample}/vcf/indels"]}
                    )
                .concat(
                    clairs_merge_final_indels.out.indel_tbi.map{meta, tbi -> [tbi, "snp/${meta.sample}/vcf/indels"]}
                    )
                .set { outputs }
        } else {
            tmp_outputs.set { outputs }
        }

    emit:
       outputs 
}
