import groovy.json.JsonBuilder

// Define memory requirements for phasing
def req_mem = params.use_longphase ? [2, 4, 8] : [1, 2, 4]

// See https://github.com/nextflow-io/nextflow/issues/1636
// This is the only way to publish files from a workflow whilst
// decoupling the publish from the process steps.
process publish_snv {
    // publish inputs to output directory
    label "wf_somatic_snv"
    publishDir (
        params.out_dir,
        mode: "copy",
        saveAs: { dirname ? "$dirname/$fname" : fname }
    )
    input:
        tuple path(fname), val(dirname)
    output:
        path fname
    """
    """
}


process getVersions {
    label "wf_somatic_snv"
    cpus 1
    output:
        path "versions.txt"
    script:
        """
        run_clairs --version | sed 's/ /,/' >> versions.txt
        bcftools --version | sed -n 1p | sed 's/ /,/' >> versions.txt
        whatshap --version | awk '{print "whatshap,"\$0}' >> versions.txt
        longphase --version | awk 'NR==1 {print "longphase,"\$2}' >> versions.txt
        """
}


process getParams {
    label "wf_somatic_snv"
    cpus 1
    output:
        path "params.json"
    script:
        def paramsJSON = new JsonBuilder(params).toPrettyString()
        """
        # Output nextflow params object to JSON
        echo '$paramsJSON' > params.json
        """
}

// extract base metrics on the provided VCF file.
process vcfStats {
    label "wf_somatic_snv"
    cpus 2
    input:
        tuple val(meta), path(vcf), path(index)
    output:
        tuple val(meta), path("${meta.sample}.stats")
    """
    bcftools stats --threads ${task.cpus} $vcf > ${meta.sample}.stats
    """
}


// Generate report file.
process makeReport {
    label "wf_common"
    cpus 1
    input:
        tuple val(meta), 
            path(vcf), 
            path(tbi), 
            path("vcfstats.txt"), 
            path("spectra.csv"), 
            path(clinvar_vcf, stageAs: "clinvar.vcf"), 
            path("version.txt"), 
            path("params.json"),
            path(typing_vcf),
            val(typing_opt)
    output:
        tuple val(meta), path("*report.html"), emit: html
    script:
        // Define report name.
        def report_name = "${params.sample_name}.wf-somatic-snv-report.html"
        // Define clinvar file. Use staged name to avoid double staging of files.
        def clinvar = params.annotation ? "--clinvar_vcf ${clinvar_vcf}" : ""
        wfversion = workflow.manifest.version
        if( workflow.commitId ){
            wfversion = workflow.commitId
        }
        // Provide additional options for skipped germline calling, pre-computed germline calls, or
        // genotyping/hybrid mode VCF input file.
        def germline = params.germline ? "" : "--no_germline"
        def normal_vcf = params.normal_vcf ? "--normal_vcf ${file(params.normal_vcf).name}" : ""
        def typing_vcf = typing_opt ? "${typing_opt} ${typing_vcf}" : ""
        def tumor_only = params.bam_normal ? "" : "--tumor_only"
        """
        workflow-glue report_snv \\
            $report_name \\
            --versions version.txt \\
            --workflow_version ${workflow.manifest.version} \\
            --params params.json \\
            --vcf_stats vcfstats.txt \\
            --vcf $vcf \\
            --mut_spectra spectra.csv \\
            ${clinvar} ${germline} ${normal_vcf} ${typing_vcf} ${tumor_only}
        """
}

// Define the appropriate model to use.
process lookup_clair3_model {
    label "wf_somatic_snv"
    cpus 1
    input:
        path("lookup_table")
        val basecall_model
    output:
        stdout
    shell:
    '''
    resolve_clair3_model.py lookup_table '!{basecall_model}' 
    '''
}


//
// Individual ClairS subprocesses to better handle the workflow.
//
// Prepare chunks and contigs list for parallel processing.
process wf_build_regions {
    label "wf_somatic_snv"
    cpus 1
    input:
        tuple path(normal_bam, stageAs: "normal/*"), 
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"), 
            path(tumor_bai, stageAs: "tumor/*"), 
            val(meta) 
        tuple path(ref), path(fai), path(ref_cache), env(REF_PATH)
        val model
        path bed
        tuple path(typing_vcf), val(typing_opt)
            
    output:
        tuple val(meta), path("${meta.sample}/tmp/CONTIGS"), emit: contigs_file
        tuple val(meta), path("${meta.sample}/tmp/CHUNK_LIST"), emit: chunks_file
        tuple val(meta), path("${meta.sample}/tmp/split_beds"), emit: split_beds
    script:
        // Define additional inputs, such as target contigs, target region as bed file and more.
        def bedargs = params.bed ? "--bed_fn ${bed}" : ""
        def include_ctgs = params.include_all_ctgs ? "--include_all_ctgs" : ""
        def target_ctg = params.ctg_name == "EMPTY" ? "" : "--ctg_name ${params.ctg_name}"
        def indels_call = params.basecaller_cfg.startsWith('dna_r10') ? "--enable_indel_calling" : ""
        // Enable hybrid/genotyping mode if passed
        def typing_mode = typing_opt ? "${typing_opt} ${typing_vcf}" : ""
        """
        \$CLAIRS_PATH/run_clairs ${target_ctg} ${include_ctgs} \\
            --tumor_bam_fn ${tumor_bam.getName()} \\
            --normal_bam_fn ${normal_bam.getName()} \\
            --ref_fn ${ref} \\
            --platform ${model} \\
            --output_dir ./${meta.sample} \\
            --threads ${task.cpus} \\
            --output_prefix pileup \\
            --snv_min_af ${params.snv_min_af} \\
            --min_coverage ${params.min_cov} \\
            --qual ${params.min_qual} \\
            --chunk_size 5000000 \\
            --dry_run \\
            ${bedargs} ${indels_call} ${typing_mode}

        # Save empty file to prevent empty directory errors on AWS
        touch ${meta.sample}/tmp/split_beds/EMPTY
        """
}

// Select heterozygote sites using both normal and tumor germline calls
// for phasing.
process clairs_select_het_snps {
    label "wf_somatic_snv"
    cpus 2
    input:
        tuple val(meta_tumor), 
            path(tumor_vcf, stageAs: "tumor.vcf.gz"), 
            path(tumor_tbi, stageAs: "tumor.vcf.gz.tbi"),
            val(meta_normal),
            path(normal_vcf, stageAs: "normal.vcf.gz"),
            path(normal_tbi, stageAs: "normal.vcf.gz.tbi"),
            val(contig)
            
    output:
        tuple val(meta_normal), val(contig), path("split_folder/${contig}.vcf.gz"), path("split_folder/${contig}.vcf.gz.tbi"), emit: normal_hets
        tuple val(meta_tumor), val(contig), path("split_folder/${contig}.vcf.gz"), path("split_folder/${contig}.vcf.gz.tbi"), emit: tumor_hets
    script:
        def normal_hets_phasing = params.use_normal_hets_for_phasing ? "True" : "False"
        def tumor_hets_phasing = params.use_tumor_hets_for_phasing ? "True" : "False"
        def hets_indels_phasing = params.use_het_indels_for_phasing ? "True" : "False"
        """
        pypy3 \$CLAIRS_PATH/clairs.py select_hetero_snp_for_phasing \\
            --tumor_vcf_fn tumor.vcf.gz \\
            --normal_vcf_fn normal.vcf.gz \\
            --output_folder split_folder/ \\
            --ctg_name ${contig} \\
            --use_heterozygous_snp_in_normal_sample_for_intermediate_phasing ${normal_hets_phasing} \\
            --use_heterozygous_snp_in_tumor_sample_for_intermediate_phasing ${tumor_hets_phasing} \\
            --use_heterozygous_indel_for_intermediate_phasing ${hets_indels_phasing}

        bgzip -c split_folder/${contig}.vcf > split_folder/${contig}.vcf.gz
        tabix split_folder/${contig}.vcf.gz
        """
        
}

// Run variant phasing on each contig using either longphase or whatshap.
process clairs_phase {
    label "wf_somatic_snv"
    cpus { req_mem[task.attempt - 1] }
    // Define memory from phasing tool and number of attempt
    maxRetries 2
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta), 
            val(contig), 
            path(vcf), 
            path(tbi),
            path(bam), 
            path(bai), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
            
    output:
        tuple val(meta), 
            val(contig), 
            path("phased_${meta.sample}_${meta.type}_${contig}.vcf.gz"), 
            path("phased_${meta.sample}_${meta.type}_${contig}.vcf.gz.tbi"), 
            path(bam), 
            path(bai), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            emit: phased_data
    script:
        def use_indels = params.use_het_indels_for_phasing ? "--indels" : ""
        if (params.use_longphase)
        """
        echo "Using longphase for phasing"
        # longphase needs decompressed 
        gzip -dc ${vcf} > variants.vcf
        longphase phase --ont -o phased_${meta.sample}_${meta.type}_${contig} \\
            -s variants.vcf -b ${bam} -r ${ref} -t ${task.cpus} ${use_indels}
        bgzip phased_${meta.sample}_${meta.type}_${contig}.vcf
        tabix -f -p vcf phased_${meta.sample}_${meta.type}_${contig}.vcf.gz
        """
        else
        """
        echo "Using whatshap for phasing"
        whatshap phase \\
            --output phased_${meta.sample}_${meta.type}_${contig}.vcf.gz \\
            --reference ${ref} \\
            --chromosome ${contig} \\
            --distrust-genotypes \\
            --ignore-read-groups \\
            ${vcf} \\
            ${bam}
        tabix -f -p vcf phased_${meta.sample}_${meta.type}_${contig}.vcf.gz
        """
}

// Run whatshap haplotag on the bam file
process clairs_haplotag {
    label "wf_somatic_snv"
    cpus 4
    input:
        tuple val(meta), 
            val(contig), 
            path(vcf), 
            path(tbi),
            path(bam), 
            path(bai), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
            
    output:
        tuple val(meta.sample), 
            val(contig), 
            path("${meta.sample}_${meta.type}_${contig}.bam"), 
            path("${meta.sample}_${meta.type}_${contig}.bam.bai"), 
            val(meta),
            emit: phased_data
    script:
    def threads = Math.max(1, task.cpus - 1)
    if (params.use_longphase_haplotag)
        """
        longphase haplotag \
            -o ${meta.sample}_${meta.type}_${contig} \
            --reference ${ref} \
            --region ${contig} \
            -s ${vcf} \
            -b ${bam} \
            --threads ${task.cpus}
        samtools index -@ ${threads} ${meta.sample}_${meta.type}_${contig}.bam
        """
    else
        """
        whatshap haplotag \\
            --reference ${ref} \\
            --regions ${contig} \\
            --ignore-read-groups \\
            ${vcf} \\
            ${bam} \\
        | samtools view -b -1 -@3 -o ${meta.sample}_${meta.type}_${contig}.bam##idx##${meta.sample}_${meta.type}_${contig}.bam.bai --write-index --no-PG
        """
}


// Extract candidate regions to process
process clairs_extract_candidates {
    label "wf_somatic_snv"
    cpus {2 * task.attempt}
    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta),
            val(region),
            path(normal_bam, stageAs: "normal/*"),
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"),
            path(tumor_bai, stageAs: "tumor/*"),
            path(split_beds),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model)
        tuple path(typing_vcf), val(typing_opt)
    output:
    tuple val(meta),
            val(region),
            path('candidates/CANDIDATES_FILE_*'),
            path("candidates/${region.contig}.*"),
            emit: candidates_snvs,
            optional: true
    tuple val(meta),
            val(region),
            path('indels/INDEL_CANDIDATES_FILE_*'),
            path("indels/${region.contig}.*_indel"),
            emit: candidates_indels,
            optional: true
    tuple val(meta),
            val(region),
            path("hybrid/${region.contig}.*_hybrid_info"),
            emit: candidates_hybrids,
            optional: true
    tuple val(meta),
            val(region),
            path("candidates/bed/*"),
            emit: candidates_bed,
            optional: true

    script:
        def bedfile = params.bed ? "" : ""
        // Call indels when r10 model is provided.
        def indel_min_af = model.startsWith('ont_r10') ? "--indel_min_af ${params.indel_min_af}" : "--indel_min_af 1.00"
        def select_indels = model.startsWith('ont_r10') ? "--select_indel_candidates True" : "--select_indel_candidates False"
        // Enable hybrid/genotyping mode if passed
        def typing_mode = typing_opt ? "${typing_opt} ${typing_vcf}" : ""
        // If the model is for liquid tumor, use specific settings
        def liquid = model.endsWith("liquid") || params.liquid_tumor ? "--enable_params_for_liquid_tumor_sample True" : ""
        // If min_bq provided, use it; otherwise, if HAC model set min_bq to 15. 
        def min_bq = params.min_bq ? "--min_bq ${params.min_bq}" : model =~ "hac" ? "--min_bq 15" : ""
        """
        # Create output folder structure
        mkdir candidates indels hybrid
        # Create candidates
        pypy3 \$CLAIRS_PATH/clairs.py extract_pair_candidates \\
            --tumor_bam_fn ${tumor_bam.getName()} \\
            --normal_bam_fn ${normal_bam.getName()} \\
            --ref_fn ${ref} \\
            --samtools samtools \\
            --snv_min_af ${params.snv_min_af} \\
            ${indel_min_af} \\
            --chunk_id ${region.chunk_id} \\
            --chunk_num ${region.total_chunks} \\
            --ctg_name ${region.contig} \\
            --platform ont \\
            --min_coverage ${params.min_cov} \\
            --bed_fn ${split_beds}/${region.contig} \\
            --candidates_folder candidates/ \\
            ${select_indels} \\
            --output_depth True \\
            ${typing_mode} \\
            ${liquid} \\
            ${min_bq}
        for i in `ls candidates/INDEL_*`; do
            echo "Moved \$i"
            mv \$i indels/
        done
        for i in `ls candidates/*_indel`; do 
            echo "Moved \$i"
            mv \$i indels/
        done
        for i in `ls candidates/*_hybrid_info`; do 
            echo "Moved \$i"
            mv \$i hybrid/
        done
        """
}

// Create Paired Tensors for pileup variant calling step
process clairs_create_paired_tensors {
    label "wf_somatic_snv"
    cpus { 2 * task.attempt }
    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta),
            val(region),
            path(normal_bam, stageAs: "normal/*"),
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"),
            path(tumor_bai, stageAs: "tumor/*"),
            path(split_beds),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model),
            path(candidate),
            path(intervals)
    output:
        tuple val(meta),
            val(region),
            path(normal_bam),
            path(normal_bai),
            path(tumor_bam),
            path(tumor_bai),
            path(split_beds),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model),
            path(candidate),
            path(intervals),
            path("tmp/pileup_tensor_can/")
            
    script:
        // If min_bq provided, use it; otherwise, if HAC model set min_bq to 15. 
        def min_bq = params.min_bq ? "--min_bq ${params.min_bq}" : model =~ "hac" ? "--min_bq 15" : ""
        """
        mkdir -p tmp/pileup_tensor_can
        pypy3 \$CLAIRS_PATH/clairs.py create_pair_tensor_pileup \\
            --normal_bam_fn ${normal_bam.getName()} \\
            --tumor_bam_fn ${tumor_bam.getName()} \\
            --ref_fn ${ref} \\
            --samtools samtools \\
            --ctg_name ${region.contig} \\
            --candidates_bed_regions ${intervals} \\
            --tensor_can_fn tmp/pileup_tensor_can/${intervals.getName()} \\
            --platform ont \\
            ${min_bq}
        """
}


// Perform pileup variant prediction using the paired tensors from clairs_create_paired_tensors
process clairs_predict_pileup {
    label "wf_somatic_snv"
    cpus {2 * task.attempt}
    maxRetries 3
    // Add 134 as a possible error status. This is because currently ClairS fails with
    // this error code when libomp.so is already instantiated. This error is rather mysterious
    // in the sense that it occur spuriously in clusters, both using our own or the official
    // ClairS container with singularity. Further investigations are ongoing, but being the issue
    // unrelated with the workflow, add an exception.
    errorStrategy {task.exitStatus in [134,137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta),
            val(region),
            path(normal_bam, stageAs: "normal/*"),
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"),
            path(tumor_bai, stageAs: "tumor/*"),
            path(split_beds),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model),
            path(candidate),
            path(intervals),
            path(tensor)
    output:
        tuple val(meta), path("vcf_output/p_${intervals.getName()}.vcf"), optional: true
            
    script:
        // If requested, hybrid/genotyping mode, or vcf_fn are provided, then call also reference sites and germline sites.
        def print_ref = ""
        if (params.print_ref_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ref = "--show_ref"
        } 
        def print_ger = ""
        if (params.print_germline_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ger = "--show_germline"
        }
        def run_gpu = "--use_gpu False"
        """
        mkdir vcf_output/
        python3 \$CLAIRS_PATH/clairs.py predict \\
            --tensor_fn ${tensor}/${intervals.getName()} \\
            --call_fn vcf_output/p_${intervals.getName()}.vcf \\
            --chkpnt_fn \${CLAIR_MODELS_PATH}/${model}/pileup.pkl \\
            --platform ont \\
            ${run_gpu} \\
            --ctg_name ${region.contig} \\
            --pileup \\
            ${print_ref} \\
            ${print_ger}
        """
}

// Merge single-contig pileup variants in one VCF file
process clairs_merge_pileup {
    label "wf_somatic_snv"
    cpus 1
    input:
        tuple val(meta), 
            path(vcfs, stageAs: 'vcf_output/*'), 
            path(contig_file)
        tuple path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
    output:
        tuple val(meta), path("pileup.vcf"), emit: pileup_vcf
            
    shell:
        '''
        pypy3 $CLAIRS_PATH/clairs.py sort_vcf \\
            --ref_fn !{ref} \\
            --contigs_fn !{contig_file} \\
            --input_dir vcf_output/ \\
            --vcf_fn_prefix p_ \\
            --output_fn pileup.vcf
        '''
}


// Create Paired Tensors for full-alignment variant calling.
process clairs_create_fullalignment_paired_tensors {
    label "wf_somatic_snv"
    cpus {2 * task.attempt}
    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(sample), 
            val(contig), 
            path(tumor_bam, stageAs: "tumor/*"), 
            path(tumor_bai, stageAs: "tumor/*"),
            val(meta), 
            path(normal_bam, stageAs: "normal/*"), 
            path(normal_bai, stageAs: "normal/*"), 
            path(intervals),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model)
    output:
        tuple val(meta),
            val(contig),
            path(normal_bam),
            path(normal_bai),
            path(tumor_bam),
            path(tumor_bai),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            path(intervals),
            path("fa_tensor_can/"),
            val(model),
            emit: full_tensors
            
    script:
        """
        mkdir fa_tensor_can
        pypy3 \$CLAIRS_PATH/clairs.py create_pair_tensor \\
            --samtools samtools \\
            --normal_bam_fn ${normal_bam.getName()} \\
            --tumor_bam_fn ${tumor_bam.getName()} \\
            --ref_fn ${ref} \\
            --ctg_name ${contig} \\
            --candidates_bed_regions ${intervals} \\
            --tensor_can_fn fa_tensor_can/${intervals.getName()} \\
            --platform ont
        """
}



// Call variants using the full-alignment paired tensors 
process clairs_predict_full {
    label "wf_somatic_snv"
    cpus {2 * task.attempt}
    maxRetries 3
    // Add 134 as a possible error status. This is because currently ClairS fails with
    // this error code when libomp.so is already instantiated. This error is rather mysterious
    // in the sense that it occur spuriously in clusters, both using our own or the official
    // ClairS container with singularity. Further investigations are ongoing, but being the issue
    // unrelated with the workflow, add an exception.
    errorStrategy {task.exitStatus in [134,137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta),
            val(contig),
            path(normal_bam, stageAs: "normal/*"),
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"),
            path(tumor_bai, stageAs: "tumor/*"),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            path(intervals),
            path(tensor),
            val(model)
    output:
        tuple val(meta), path("vcf_output/fa_${intervals.getName()}.vcf"), emit: full_vcfs, optional: true
            
    script:
        // If requested, hybrid/genotyping mode, or vcf_fn are provided, then call also reference sites and germline sites.
        def print_ref = ""
        if (params.print_ref_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ref = "--show_ref"
        } 
        def print_ger = ""
        if (params.print_germline_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ger = "--show_germline"
        }
        def run_gpu = "--use_gpu False"
        """
        mkdir vcf_output/
        python3 \$CLAIRS_PATH/clairs.py predict \\
            --tensor_fn ${tensor}/${intervals.getName()} \\
            --call_fn vcf_output/fa_${intervals.getName()}.vcf \\
            --chkpnt_fn \${CLAIR_MODELS_PATH}/${model}/full_alignment.pkl \\
            --platform ont \\
            ${run_gpu} \\
            --ctg_name ${contig} \\
            ${print_ref} ${print_ger}
        """
}


// Merge single-contigs full-alignment variants in a single VCF file
process clairs_merge_full {
    label "wf_somatic_snv"
    cpus {2 * task.attempt}
    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta), 
            path(vcfs, stageAs: 'vcf_output/*'), 
            path(contig_file), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
    output:
        tuple val(meta), path("full_alignment.vcf"), emit: full_vcf
            
    shell:
        '''
        pypy3 $CLAIRS_PATH/clairs.py sort_vcf \\
            --ref_fn !{ref} \\
            --contigs_fn !{contig_file} \\
            --input_dir vcf_output/ \\
            --vcf_fn_prefix fa_ \\
            --output_fn full_alignment.vcf
        '''
}

// Filter variants based on haplotype information.
process clairs_full_hap_filter {
    label "wf_somatic_snv"
    cpus params.haplotype_filter_threads
    input:
        tuple val(meta),
            val(ctg),
            path(tumor_bams, stageAs: "bams/*"),
            path(tumor_bai, stageAs: "bams/*"),
            path("germline.vcf.gz"),
            path("germline.vcf.gz.tbi"),
            path("pileup.vcf"),
            path("full_alignment.vcf"),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(variant_type)
    output:
        tuple val(meta), 
            val(variant_type),
            path("vcf_output/*pileup_filter.vcf"),
            path("vcf_output/*full_alignment_filter.vcf"),
            emit: filtered_vcfs
            
    script:
        def debug = params.clairs_debug ? "--debug" : ""
        // If a germline VCF file has been computed, then use it; otherwise set it to None.
        def germline = params.germline ? "--germline_vcf_fn germline.vcf.gz" : ""
        // If reference calls are requested, or it is a hybrid/genotyping mode, then add --show_ref option.
        def show_ref = params.print_ref_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf ? "--show_ref" : ""
        // CW_2359: Define if it is indels.
        def is_indels = variant_type == 'indels' ? "--is_indel" : ""
        def pileup_output_fn = variant_type == 'indels' ? "indel_pileup_filter.vcf" : "pileup_filter.vcf"
        def fa_output_fn = variant_type == 'indels' ? "indel_full_alignment_filter.vcf" : "full_alignment_filter.vcf"
        """
        mkdir vcf_output/
        pypy3 \$CLAIRS_PATH/clairs.py haplotype_filtering \\
            --tumor_bam_fn bams/${meta.sample}_${meta.type}_ \\
            --ref_fn ${ref} \\
            ${germline} \\
            --pileup_vcf_fn pileup.vcf \\
            --full_alignment_vcf_fn full_alignment.vcf \\
            --output_dir vcf_output/ \\
            --samtools samtools \\
            --threads ${task.cpus} \\
            --ctg_name ${ctg} \\
            ${show_ref} \\
            ${is_indels} \\
            ${debug}
        mv vcf_output/${pileup_output_fn} vcf_output/${ctg}_${pileup_output_fn}
        mv vcf_output/${fa_output_fn} vcf_output/${ctg}_${fa_output_fn}
        """
}

// Module to convert fai index to bed
process concat_hap_filtered_vcf {
    label "wf_somatic_snv"
    cpus 2
    input:
        tuple val(meta), 
            val(variant_type),
            path("pileups/*"),
            path("fullalign/*"),
            path(contig_file),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)

    output:
        tuple val(meta), 
            path("${variant_type}_pileup_filter.vcf"),
            path("${variant_type}_full_alignment_filter.vcf"),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            emit: filtered_vcfs

    script:
    // Concatenate the VCFs for the individual contigs using sort_vcf.
    // This is used over bcftools concat as the outputs are not valid
    // VCFs, and the internal tool is more tolerant. The pileup VCFs
    // and full-alignment VCFs are concatenated separately.
    """
    # Concatenate the individual pileups
    pypy3 \$CLAIRS_PATH/clairs.py sort_vcf \\
            --ref_fn ${ref} \\
            --contigs_fn ${contig_file} \\
            --input_dir pileups/ \\
            --vcf_fn_prefix chr \\
            --output_fn ${variant_type}_pileup_filter.vcf

    # Concatenate the individual full-alignments
    pypy3 \$CLAIRS_PATH/clairs.py sort_vcf \\
            --ref_fn ${ref} \\
            --contigs_fn ${contig_file} \\
            --input_dir fullalign/ \\
            --vcf_fn_prefix chr \\
            --output_fn ${variant_type}_full_alignment_filter.vcf
    """
}

// Final merging of pileup and full-alignment sites.
process clairs_merge_final {
    label "wf_somatic_snv"
    cpus 2
    input:
        tuple val(meta),
            path(pileup_filter),
            path(full_alignment_filter),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
    output:    
        tuple val(meta), path("${meta.sample}_somatic_snv.vcf.gz"), emit: pileup_vcf
        tuple val(meta), path("${meta.sample}_somatic_snv.vcf.gz.tbi"), emit: pileup_tbi
            
    script:
        """
        pypy3 \$CLAIRS_PATH/clairs.py merge_vcf \\
            --ref_fn ${ref} \\
            --pileup_vcf_fn ${pileup_filter} \\
            --full_alignment_vcf_fn ${full_alignment_filter} \\
            --output_fn ${meta.sample}_somatic_snv.vcf \\
            --platform ont \\
            --qual ${params.min_qual} \\
            --sample_name ${meta.sample}

        # Check if the number of variants is > 0
        if [ "\$( bcftools index --threads ${task.cpus} -n ${meta.sample}_somatic_snv.vcf.gz )" -eq 0 ]; \\
        then echo "[INFO] Exit in pileup variant calling"; exit 1; fi
        """
}

/*
*  Add modules to call indels
*/ 
// TODO: Several of these modules can probably be replaced with a modified version of one module, then imported with several aliases and appropriate switches
// Create paired tensors for the pileup variant calling of the indels 
process clairs_create_paired_tensors_indels {
    label "wf_somatic_snv"
    cpus {2 * task. attempt}
    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta),
            val(region),
            path(normal_bam, stageAs: "normal/*"),
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"),
            path(tumor_bai, stageAs: "tumor/*"),
            path(split_beds),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model),
            path(candidate),
            path(intervals)
    output:
        tuple val(meta),
            val(region),
            path(normal_bam),
            path(normal_bai),
            path(tumor_bam),
            path(tumor_bai),
            path(split_beds),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model),
            path(candidate),
            path(intervals),
            path("tmp/indel_pileup_tensor_can/")
            
    script:
        """
        mkdir -p tmp/indel_pileup_tensor_can
        pypy3 \$CLAIRS_PATH/clairs.py create_pair_tensor_pileup \\
            --normal_bam_fn ${normal_bam.getName()} \\
            --tumor_bam_fn ${tumor_bam.getName()} \\
            --ref_fn ${ref} \\
            --samtools samtools \\
            --ctg_name ${region.contig} \\
            --candidates_bed_regions ${intervals} \\
            --tensor_can_fn tmp/indel_pileup_tensor_can/${intervals.getName()} \\
            --platform ont
        """
}

// Perform pileup variant prediction of indels using the paired tensors from clairs_create_paired_tensors
process clairs_predict_pileup_indel {
    label "wf_somatic_snv"
    cpus {2 * task.attempt}
    maxRetries 3
    // Add 134 as a possible error status. This is because currently ClairS fails with
    // this error code when libomp.so is already instantiated. This error is rather mysterious
    // in the sense that it occur spuriously in clusters, both using our own or the official
    // ClairS container with singularity. Further investigations are ongoing, but being the issue
    // unrelated with the workflow, add an exception.
    errorStrategy {task.exitStatus in [134,137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta),
            val(region),
            path(normal_bam, stageAs: "normal/*"),
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"),
            path(tumor_bai, stageAs: "tumor/*"),
            path(split_beds),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model),
            path(candidate),
            path(intervals),
            path(tensor)
    output:
        tuple val(meta), path("vcf_output/indel_p_${intervals.getName()}.vcf"), optional: true
            
    script:
        // If requested, hybrid/genotyping mode, or vcf_fn are provided, then call also reference sites and germline sites.
        def print_ref = ""
        if (params.print_ref_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ref = "--show_ref"
        } 
        def print_ger = ""
        if (params.print_germline_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ger = "--show_germline"
        }
        def run_gpu = "--use_gpu False"
        """
        mkdir vcf_output/
        python3 \$CLAIRS_PATH/clairs.py predict \\
            --tensor_fn ${tensor}/${intervals.getName()} \\
            --call_fn vcf_output/indel_p_${intervals.getName()}.vcf \\
            --chkpnt_fn \${CLAIR_MODELS_PATH}/${model}/indel/pileup.pkl \\
            --platform ont \\
            ${run_gpu} \\
            --ctg_name ${region.contig} \\
            --pileup \\
            --enable_indel_calling True \\
            ${print_ref} \\
            ${print_ger}
        """
}

// Merge single-contigs pileup indels in a single VCF file
process clairs_merge_pileup_indels {
    label "wf_somatic_snv"
    cpus 1
    input:
        tuple val(meta), 
            path(vcfs, stageAs: 'vcf_output/*'), 
            path(contig_file)
        tuple path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
    output:
        tuple val(meta), path("indels_pileup.vcf"), emit: pileup_vcf
            
    shell:
        '''
        pypy3 $CLAIRS_PATH/clairs.py sort_vcf \\
            --ref_fn !{ref} \\
            --contigs_fn !{contig_file} \\
            --input_dir vcf_output/ \\
            --vcf_fn_prefix indel_p_ \\
            --output_fn indels_pileup.vcf
        '''
}

// Create paired tensors for the full-alignment variant calling of the indels 
process clairs_create_fullalignment_paired_tensors_indels {
    label "wf_somatic_snv"
    cpus {2 * task.attempt}
    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple val(sample), 
            val(contig), 
            path(tumor_bam, stageAs: "tumor/*"), 
            path(tumor_bai, stageAs: "tumor/*"),
            val(meta), 
            path(normal_bam, stageAs: "normal/*"), 
            path(normal_bai, stageAs: "normal/*"), 
            path(intervals),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(model)
    output:
        tuple val(meta),
            val(contig),
            path(normal_bam),
            path(normal_bai),
            path(tumor_bam),
            path(tumor_bai),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            path(intervals),
            path("fa_tensor_can_indels/"),
            val(model),
            emit: full_tensors
            
    script:
        """
        mkdir fa_tensor_can_indels
        pypy3 \$CLAIRS_PATH/clairs.py create_pair_tensor \\
            --samtools samtools \\
            --normal_bam_fn ${normal_bam.getName()} \\
            --tumor_bam_fn ${tumor_bam.getName()} \\
            --ref_fn ${ref} \\
            --ctg_name ${contig} \\
            --candidates_bed_regions ${intervals} \\
            --tensor_can_fn fa_tensor_can_indels/${intervals.getName()} \\
            --platform ont
        """
}

// Perform full-alignment variant prediction of indels using the paired tensors from clairs_create_paired_tensors
process clairs_predict_full_indels {
    label "wf_somatic_snv"
    cpus { 2 * task.attempt }
    maxRetries 3
    // Add 134 as a possible error status. This is because currently ClairS fails with
    // this error code when libomp.so is already instantiated. This error is rather mysterious
    // in the sense that it occur spuriously in clusters, both using our own or the official
    // ClairS container with singularity. Further investigations are ongoing, but being the issue
    // unrelated with the workflow, add an exception.
    errorStrategy {task.exitStatus in [134,137,140] ? 'retry' : 'finish'}
    input:
        tuple val(meta),
            val(contig),
            path(normal_bam, stageAs: "normal/*"),
            path(normal_bai, stageAs: "normal/*"),
            path(tumor_bam, stageAs: "tumor/*"),
            path(tumor_bai, stageAs: "tumor/*"),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            path(intervals),
            path(tensor),
            val(model)
    output:
        tuple val(meta), path("vcf_output/indels_fa_${intervals.getName()}.vcf"), emit: full_vcfs, optional: true
            
    script:
        // If requested, hybrid/genotyping mode, or vcf_fn are provided, then call also reference sites and germline sites.
        def print_ref = ""
        if (params.print_ref_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ref = "--show_ref"
        } 
        def print_ger = ""
        if (params.print_germline_calls || params.hybrid_mode_vcf || params.genotyping_mode_vcf || params.vcf_fn != 'EMPTY'){
            print_ger = "--show_germline"
        }
        def run_gpu = "--use_gpu False"
        """
        mkdir vcf_output/
        python3 \$CLAIRS_PATH/clairs.py predict \\
            --tensor_fn ${tensor}/${intervals.getName()} \\
            --call_fn vcf_output/indels_fa_${intervals.getName()}.vcf \\
            --chkpnt_fn \${CLAIR_MODELS_PATH}/${model}/indel/full_alignment.pkl \\
            --platform ont \\
            ${run_gpu} \\
            --ctg_name ${contig} \\
            --enable_indel_calling True \\
            ${print_ref} ${print_ger}
        """
}

// Merge single-contigs full-alignment indels in a single VCF file
process clairs_merge_full_indels {
    label "wf_somatic_snv"
    cpus 1
    input:
        tuple val(meta), 
            path(vcfs, stageAs: 'vcf_output/*'), 
            path(contig_file), 
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
    output:
        tuple val(meta), path("indels_full_alignment.vcf"), emit: full_vcf
            
    shell:
        '''
        pypy3 $CLAIRS_PATH/clairs.py sort_vcf \\
            --ref_fn !{ref} \\
            --contigs_fn !{contig_file} \\
            --input_dir vcf_output/ \\
            --vcf_fn_prefix indels_fa_ \\
            --output_fn indels_full_alignment.vcf
        '''
}

// Final merging of pileup and full-alignment indels.
process clairs_merge_final_indels {
    label "wf_somatic_snv"
    cpus 2
    input:
        tuple val(meta),
            path(pileup_indels),
            path(full_alignment_indels),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
    output:    
        tuple val(meta), path("${meta.sample}_somatic_indels.vcf.gz"), emit: indel_vcf
        tuple val(meta), path("${meta.sample}_somatic_indels.vcf.gz.tbi"), emit: indel_tbi
            
    script:
        """
        pypy3 \$CLAIRS_PATH/clairs.py merge_vcf \\
            --ref_fn ${ref} \\
            --pileup_vcf_fn ${pileup_indels} \\
            --full_alignment_vcf_fn ${full_alignment_indels} \\
            --output_fn ${meta.sample}_somatic_indels.vcf \\
            --platform ont \\
            --qual ${params.min_qual} \\
            --sample_name ${meta.sample} \\
            --enable_indel_calling True \\
            --indel_calling

        # Check if the number of variants is > 0
        if [ "\$( bcftools index --threads ${task.cpus} -n ${meta.sample}_somatic_indels.vcf.gz )" -eq 0 ]; \\
        then echo "[INFO] Exit in pileup variant calling"; exit 1; fi
        """
}
/*
 * Post-processing processes
 */

// CW-1949: add_missing_variants adds all types of sites to the resulting VCF file,
// regardless of the input. As a consequence, merging introduces duplicated sites, which can
// theorethically be dealt with by bcftools norm. However, bcftools norm drops all
// sites that lack a genotype, which are most of the sites detected by the genotyping mode.
// We therefore extract indels and SNPs independently, allowing then to merge them without
// duplicated sites.
process getVariantType {
    cpus 2
    input:
        tuple val(meta), path(vcf), path(tbi)
        val variant_type
    output:
        tuple val(meta), path("${vcf.simpleName}.subset.vcf.gz"), emit: vcf
        tuple val(meta), path("${vcf.simpleName}.subset.vcf.gz.tbi"), emit: tbi
    """
    bcftools view --threads ${task.cpus} -O z -v ${variant_type} ${vcf} > ${vcf.simpleName}.subset.vcf.gz && \
        tabix -p vcf ${vcf.simpleName}.subset.vcf.gz
    """
}


// Concatenate SNVs and Indels in a single VCF file. 
process clairs_merge_snv_and_indels {
    cpus 2
    input:
        tuple val(meta), path(vcfs, stageAs: 'VCFs/*'), path(tbis, stageAs: 'VCFs/*')
    output:
        tuple val(meta), path("${meta.sample}_somatic.vcf.gz"), emit: pileup_vcf
        tuple val(meta), path("${meta.sample}_somatic.vcf.gz.tbi"), emit: pileup_tbi
            
    script:
    // CW-1949: bcftools sort always drop sites without alleles/genotypes, which is not
    // ideal for this mode. bedtools doesn't have this issue, and therefore use this instead.
    if (params.genotyping_mode_vcf || params.hybrid_mode_vcf)
    """
    bcftools concat --threads 1 -O v -a VCFs/*.vcf.gz | \\
        bedtools sort -header -i - | \\
            bcftools view --threads 1 -O z > ${meta.sample}_somatic.vcf.gz && \\
        tabix -p vcf ${meta.sample}_somatic.vcf.gz
    """
    else
    """
    bcftools concat --threads 2 -a VCFs/*.vcf.gz | \\
        bcftools sort -m 2G -T ./ -O z > ${meta.sample}_somatic.vcf.gz && \\
        tabix -p vcf ${meta.sample}_somatic.vcf.gz
    """
}

// Concatenate the single-chromosome haplotagged bam files
process concat_bams {
    label "wf_somatic_snv"
    cpus 8
    input:
        tuple val(meta), 
            path("bams/*"), 
            path("bams/*"),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH),
            val(xam_fmt),
            val(xai_fmt)
    output:    
        tuple val(meta),
            path("${meta.sample}_${meta.type}.ht.${xam_fmt}"),
            path("${meta.sample}_${meta.type}.ht.${xam_fmt}.${xai_fmt}"), emit: tagged_xams
            
    script:
        def threads = Math.max(task.cpus - 1, 1)
        """
        # ensure that this file does not exists
        if [ -f seq_list.txt ]; then
            rm seq_list.txt
        fi
        # pick the "first" bam and read its SQ list to determine sort order
        samtools view -H --no-PG `ls bams/*.bam | head -n1` | grep '^@SQ' | sed -nE 's,.*SN:([^[:space:]]*).*,\\1,p' > seq_list.txt
        # append present contigs to a file of file names, to cat according to SQ order
        while read sq; do
            if [ -f "bams/${meta.sample}_${meta.type}_\${sq}.bam" ]; then
                echo "bams/${meta.sample}_${meta.type}_\${sq}.bam" >> cat.fofn
            fi
        done < seq_list.txt
        if [ ! -s cat.fofn ]; then
            echo "No haplotagged inputs to cat? Are the input file names staged correctly?"
            exit 70 # EX_SOFTWARE
        fi

        # cat just cats files of the same format, if we want CRAM, we'll have to call samtools view ourselves
        if [ "${xam_fmt}" = "cram" ]; then
            samtools cat -b cat.fofn --no-PG -o - | \
                samtools view --no-PG -@ ${threads} --reference ${ref} -O cram --write-index -o "${meta.sample}_${meta.type}.ht.cram##idx##${meta.sample}_${meta.type}.ht.cram.crai"
        else
            samtools cat -b cat.fofn --no-PG -@ ${threads} -o "${meta.sample}_${meta.type}.ht.bam"
            samtools index -@ ${threads} -b "${meta.sample}_${meta.type}.ht.bam"
        fi
        """
}

// Annotate the change type counts (e.g. mutation_type=AAA>ATA)
process change_count {
    label "wf_common"
    cpus 1
    input:
        tuple val(meta),
            path("input.vcf.gz"),
            path("input.vcf.gz.tbi"),
            path(ref), 
            path(fai), 
            path(ref_cache), 
            env(REF_PATH)
    output:    
        tuple val(meta), path("${meta.sample}.wf-somatic-snv.vcf.gz"), emit: mutype_vcf
        tuple val(meta), path("${meta.sample}.wf-somatic-snv.vcf.gz.tbi"), emit: mutype_tbi
        tuple val(meta), path("${meta.sample}_changes.csv"), emit: changes
        tuple val(meta), path("${meta.sample}_changes.json"), emit: changes_json
            
    script:
        """
        workflow-glue annotate_mutations input.vcf.gz "${meta.sample}.wf-somatic-snv.vcf.gz" --json -k 3 --genome ${ref}
        tabix -p vcf "${meta.sample}.wf-somatic-snv.vcf.gz"
        """
}

/*
 * Genotyping/hybrid mode
 * Add missing variants from a given VCF file to a target VCF file
 */
process add_missing_vars {
    label "wf_somatic_snv"
    cpus 1
    input:
        tuple val(meta), 
            path(vcf), 
            path(tbi),
            path('candidates/*'),
            path('candidates/bed/*')
        tuple path(typing_vcf), val(typing_opt)
            
    output:
        tuple val(meta), path("${vcf.simpleName}.gt.vcf.gz"), emit: pileup_vcf
        tuple val(meta), path("${vcf.simpleName}.gt.vcf.gz.tbi"), emit: pileup_tbi
            
    script:
        // Enable hybrid/genotyping mode if passed
        def typing_mode = typing_opt ? "${typing_opt} ${typing_vcf}" : ""
        """
        pypy3 \$CLAIRS_PATH/clairs.py add_back_missing_variants_in_genotyping \\
            ${typing_mode} \\
            --call_fn ${vcf} \\
            --candidates_folder candidates/ \\
            --output_fn ${vcf.simpleName}.gt.vcf
        """
}
