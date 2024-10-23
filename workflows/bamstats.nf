process bamstats {
    label "wf_common"
    cpus 4
    input:
        tuple path(xam), path(xam_idx), val(xam_meta)
        tuple path(ref), path(ref_idx), path(ref_cache), env(REF_PATH)

    output:
        tuple val(xam_meta), path("*.readstats.tsv.gz"), emit: read_stats
        tuple val(xam_meta), path("*.flagstat.tsv"), emit: flagstat
        tuple val(xam_meta), path("hists_${xam_meta.sample}_${xam_meta.type}"), emit: hists
        // Unlike the other outputs, ignore the meta.
        path "${params.sample_name}.${xam_meta.type}.runids.txt", emit: runids
        tuple val(xam_meta), path("${params.sample_name}.${xam_meta.type}.basecallers.txt"), emit: basecallers
    script:
    def cores = task.cpus > 1 ? task.cpus - 1 : 1
    """
    bamstats ${xam} \\
        -s ${xam_meta.sample} \\
        --threads ${cores} \\
        -i "${xam_meta.sample}.${xam_meta.type}.per-file-runids.txt" \\
        -l "${xam_meta.sample}.${xam_meta.type}.basecallers.tsv" \\
        -u \\
        --histograms hists_${xam_meta.sample}_${xam_meta.type} \\
        -f ${xam_meta.sample}_${xam_meta.type}.flagstat.tsv \\
        | gzip > "${xam_meta.sample}_${xam_meta.type}.readstats.tsv.gz"

    # get unique run IDs
    awk -F '\\t' '
        NR==1 {for (i=1; i<=NF; i++) {ix[\$i] = i}}
        # only print run_id if present
        NR>1 && \$ix["run_id"] != "" {print \$ix["run_id"]}
    ' ${xam_meta.sample}.${xam_meta.type}.per-file-runids.txt | sort | uniq > ${params.sample_name}.${xam_meta.type}.runids.txt
    # get unique basecall models
    awk -F '\\t' '
        NR==1 {for (i=1; i<=NF; i++) {ix[\$i] = i}}
        # only print basecall model if present
        NR>1 && \$ix["basecaller"] != "" {print \$ix["basecaller"]}
    ' ${xam_meta.sample}.${xam_meta.type}.basecallers.tsv | sort | uniq > ${params.sample_name}.${xam_meta.type}.basecallers.txt
    """
}

process mosdepth {
    cpus 2
    maxRetries 3
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input:
        tuple path(xam), path(xam_idx), val(xam_meta)
        file target_bed
        tuple path(ref), path(ref_idx), path(ref_cache), env(REF_PATH)
    output:
        tuple val(xam_meta), \
            path("${xam_meta.sample}_${xam_meta.type}.regions.bed.gz"),
            path("${xam_meta.sample}_${xam_meta.type}.mosdepth.global.dist.txt"),
            path("${xam_meta.sample}_${xam_meta.type}.thresholds.bed.gz"), emit: mosdepth_tuple
        tuple val(xam_meta), path("${xam_meta.sample}_${xam_meta.type}.mosdepth.summary.txt"), emit: summary
        tuple val(xam_meta), path("${xam_meta.sample}_${xam_meta.type}.per-base.bed.gz"), emit: perbase, optional: true
    script:
        def perbase_args = params.depth_intervals ? "" : "--no-per-base"
        """
        export REF_PATH=${ref}
        export MOSDEPTH_PRECISION=3
        # Convert bed into windows of given size [CW-2015]
        # The workflow now sort the bed input, merge overlapping intervals and then build windows
        # preventing crash in downstream tools.
        sort -k 1,1 -k2,2n ${target_bed} | \
            bedtools merge -i - | \
            bedtools makewindows -b - -w ${params.depth_window_size} > cut.bed
        # Run mosdepth
        mosdepth \\
            -x \\
            -t ${task.cpus} \\
            -b cut.bed \\
            --thresholds 1,10,20,30 \\
            ${perbase_args} \\
            ${xam_meta.sample}_${xam_meta.type} \\
            ${xam}
        """
}


// Get coverage to a channel
process get_coverage {
    label "wf_common"
    cpus 1
    input:
        tuple val(meta), path(mosdepth_summary)

    output:
        tuple val(meta.sample), val(meta), env(passes), env(value), emit: pass

    shell:
        '''
        # Check if the first column is "total_region", skipping the header (NR>1) and if the value is above the 
        # threshold for the right type. This is defined with the elvis ops checking the metadata for the bam, getting 
        # the file type (tumor or normal) and, therefore, the right threshold. If it is >= than the threshold, return "true"
        # otherwise return "false".
        passes=$( awk 'BEGIN{v="false"}; NR>1 && $1=="total_region" && $4>=!{meta.type == "tumor" ? params.tumor_min_coverage : params.normal_min_coverage} && v=="false" {v="true"}; END {print v}' !{mosdepth_summary} )

        # Same as above, but simply return the coverage value for the bam file in the "total_region".
        value=$( awk 'BEGIN{v=0}; NR>1 && $1=="total_region" && $4>v {v=$4}; END {print v}' !{mosdepth_summary} )
        '''
}

// Process to get the regions with genome coverage above given thresholds.
process get_region_coverage {
    cpus 1
    input:
        tuple val(meta),
            path(regions),
            path(dists),
            path(thresholds),
            path(bed)

    output:
        tuple val(meta.sample), val(meta), env(passes), env(value), emit: pass
        tuple val(meta), path("${bed.baseName}_${meta.sample}_${meta.type}.filt.bed"), emit: filt_bed
        tuple val(meta),
            path("${meta.sample}_${meta.type}.regions.filt.bed.gz"),
            path(dists),
            path(thresholds), emit: mosdepth_tuple
    shell:
    '''
    # Get intervals with average coverage above minimum
    zcat !{regions} | \
        awk '$NF>=!{meta.type == "tumor" ? params.tumor_min_coverage : params.normal_min_coverage}' | \
        bgzip -c > !{meta.sample}_!{meta.type}.regions.filt.bed.gz
    
    # Extract original regions with reasonable coverage. We first intersect, sort the kept intervals,
    # merge the adjacent and then sort again.
    sort -k1,1 -k2,2n !{bed} > a.bed
    zcat !{meta.sample}_!{meta.type}.regions.filt.bed.gz | sort -k1,1 -k2,2n > b.bed
    bedtools intersect -sorted -a a.bed -b b.bed | \
            bedtools merge -i - > !{bed.baseName}_!{meta.sample}_!{meta.type}.filt.bed && \
            rm a.bed b.bed

    # Return true if there are filtered intervals, otherwise false
    passes="false"
    if [[ $(zcat !{meta.sample}_!{meta.type}.regions.filt.bed.gz | wc -l) -gt 0 ]]; then
        passes="true"
    fi
    # If there are intervals, return average coverage, otherwise return 0
    value=$( zcat !{meta.sample}_!{meta.type}.regions.filt.bed.gz | awk 'BEGIN{v=0; n=0}; {v+=$4; n+=1}; END {if(n > 0) print v / n; else print 0}' )
    '''
}

// Define shared regions in Tumor and/or Normal passing the thresholds.
process get_shared_region {
    cpus 1
    input:
        tuple val(sample),
            path("tumor.bed"),
            path("normal.bed")

    output:
        path "filtered.bed", emit: bed_file
        tuple val(sample), path("filtered.bed"), emit: bed_tuple

    script:
    """
    # We sort and merge the all the regions passing the filters in at least one dataset.
    sort -k1,1 -k2,2n -m tumor.bed normal.bed | \
        bedtools merge -d 0 > filtered.bed
    """
}

// Make report.
process makeQCreport {
    label "wf_common"
    cpus 2
    // Increase memory up to 15GB. 
    // Most time the workflow will do fine with 7.GB, but we have seen the
    // the same reporting process in humvar failing with
    // one single sample (CW-3554) and 12.GB or memory. 
    // Since here we have twice the data to account for (tumor and normal),
    // better allowing for failures. Most times the workflow will do fine with
    // 8.GB, but if the process fails with a memory error try again doubling
    // the allowed memory

    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}
    input: 
        tuple val(meta), 
            path("hists_normal"),
            path("flagstat_normal.tsv"),
            path("summary_depth_normal/*"),
            path("depth_normal/*"),
            path("hists_tumor"),
            path("flagstat_tumor.tsv"),
            path("summary_depth_tumor/*"),
            path("depth_tumor/*"),
            path("ref.fa.fai")
        path "versions.txt"
        path "params.json"

    output:
        tuple val(meta), path("${meta.sample}.wf-somatic-variation-readQC*.html")

    script:
        // If no *_min_coverage provided, or set to null by mistake, set it to 0.
        def tumor_cvg = params.tumor_min_coverage ?: 0
        def normal_cvg = params.normal_min_coverage ?: 0
        def normal_readstats_arg = params.bam_normal ? "--hists_normal hists_normal" : ""
        def normal_flagstats_arg = params.bam_normal ? "--flagstat_normal flagstat_normal.tsv" : ""
        def normal_depth_summary_arg = params.bam_normal ? "--mosdepth_summary_normal summary_depth_normal" : ""
        def normal_depth_region_arg = params.bam_normal ? "--depth_normal depth_normal" : ""
        """
        workflow-glue report_qc \\
            --window_size ${params.depth_window_size} \\
            --tumor_cov_threshold ${tumor_cvg} \\
            --normal_cov_threshold ${normal_cvg} \\
            --sample_id ${meta.sample} \\
            --name ${meta.sample}.wf-somatic-variation-readQC \\
            --hists_tumor hists_tumor \\
            ${normal_readstats_arg} \\
            --flagstat_tumor flagstat_tumor.tsv \\
            ${normal_flagstats_arg} \\
            --mosdepth_summary_tumor summary_depth_tumor \\
            ${normal_depth_summary_arg} \\
            --depth_tumor depth_tumor \\
            ${normal_depth_region_arg} \\
            --reference_fai ref.fa.fai \\
            --versions versions.txt \\
            --params params.json \\
            --workflow_version ${workflow.manifest.version}
        """
}


process publish_qc {
    // publish inputs to output directory
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


workflow alignment_stats {
    take:
        bamfiles
        ref
        bed
        versions
        parameters
    
    main:
        // Compute bam statistics and depth
        stats = bamstats(bamfiles, ref.collect())
        depths = mosdepth(bamfiles, bed.collect(), ref.collect())
        bam_runids = stats.runids
        bam_basecalls = stats.basecallers

        // Combine the outputs for the different statistics.
        // For the reporting we will need:
        // 1. Read stats
        // 2. flagstats
        // 3. Per-base depth
        // 4. Depth summary
        stats.hists
            .combine(stats.flagstat, by:0)
            .combine(depths.summary, by:0)
            .combine(depths.mosdepth_tuple.map{meta, reg, dist, thresh ->[meta, reg]}, by:0)
            .set{ for_report }

        // Cross the results for T/N pairs
        for_report
            .branch{
                tumor: it[0].type == 'tumor'
                normal: it[0].type == 'normal'
            }
            .set{forked_channel}

        // If normal is provided, then create the channel normally
        // by crossing the normal and the tumor using the sample name.
        // Then, extract the relevant files reporting the tumor meta, followed
        // by the normal statistics and then the tumor statistics. Finally,
        // add the reference channel.
        if (params.bam_normal){
            forked_channel.normal
                .map{ it -> [ it[0].sample ] + it } 
                .cross(
                    forked_channel.tumor.map{ it -> [ it[0].sample ] + it } 
                )
                .map { normal, tumor ->
                        [tumor[1]] + normal[2..-1] + tumor[2..-1]
                    } 
                .combine(ref.map{it[1]})
                .set{paired_samples}
        } else {
            // If no normal is provided, then pass the optional file as
            // place-holder for the normal files.
            forked_channel.tumor
                .map { meta, hists, flagstats, depth_summary, depth_regions ->
                        [
                            meta,
                            file("$projectDir/data/OPTIONAL_FILE"), 
                            file("$projectDir/data/OPTIONAL_FILE"), 
                            file("$projectDir/data/OPTIONAL_FILE"), 
                            file("$projectDir/data/OPTIONAL_FILE"), 
                            hists, 
                            flagstats, 
                            depth_summary, 
                            depth_regions
                        ]
                    } 
                .combine(ref.map{it[1]})
                .set{paired_samples}
        }
        // Create the report
        makeQCreport(paired_samples, versions, parameters)

        // Prepare output channel
        // Send the output to the specified sub-directory of params.out_dir.
        // If null is passed, send it to out_dir/ directly.
        if (params.depth_intervals){
            stats.flagstat.map{meta, fstats -> [fstats, "${meta.sample}/qc/readstats"]}
                .concat(stats.read_stats.map{meta, rstats -> [rstats, "${meta.sample}/qc/readstats"]})
                .concat(stats.hists.map{meta, hists -> [hists, "${meta.sample}/qc/readstats"]})
                .concat(depths.summary.map{meta, depth_sum -> [depth_sum, "${meta.sample}/qc/coverage"]})
                .concat(depths.mosdepth_tuple
                            .map {meta, reg, dist, thresh  -> [meta, [reg, dist, thresh]] }
                            .transpose()
                            .map{meta, fname -> [fname, "${meta.sample}/qc/coverage"]})
                .concat(depths.perbase.map{meta, pbase ->[pbase, "${meta.sample}/qc/coverage"]})
                .concat(makeQCreport.out.map{it -> [it[1], null]})
                .set{outputs}
        } else {
            stats.flagstat.map{meta, fstats -> [fstats, "${meta.sample}/qc/readstats"]}
                .concat(stats.read_stats.map{meta, rstats -> [rstats, "${meta.sample}/qc/readstats"]})
                .concat(stats.hists.map{meta, hists -> [hists, "${meta.sample}/qc/readstats"]})
                .concat(depths.summary.map{meta, depth_sum -> [depth_sum, "${meta.sample}/qc/coverage"]})
                .concat(depths.mosdepth_tuple
                            .map {meta, reg, dist, thresh  -> [meta, [reg, dist, thresh]] }
                            .transpose()
                            .map{meta, fname -> [fname, "${meta.sample}/qc/coverage"]})
                .concat(makeQCreport.out.map{meta, report -> [report, null]})
                .set{outputs}
        }

        emit:
            outputs = outputs
            coverages = depths.summary
            mosdepth_tuple = depths.mosdepth_tuple
            paired_qc = paired_samples
            report_qc = makeQCreport.out
            runids = bam_runids
            basecallers = bam_basecalls
}
