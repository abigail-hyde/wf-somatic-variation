/*
 * This sub-workflow acts as a wrapper around `ingress.nf`,
 * extending its functionality to do additional input preprocessing:
 *  - check whether the aligned BAM files match the input reference
 *  - index the input BAM file
 *  - (re-)align the input BAM if they are unaligned or mismatch the reference
 */
include { xam_ingress } from './ingress.nf'

// Minimap2 mapping
process minimap2_ubam {
    cpus {4 * task.attempt}
    maxRetries 1
    errorStrategy {task.exitStatus in [137,140] ? 'retry' : 'finish'}

    input:
        path reference
        tuple val(meta), path(reads), path(reads_idx)
        tuple val(extension), val(idx_extension)
    // Output can either be a BAM or a CRAM. If the user requires SV, the output will be a BAM
    // This is to simplify the input files in the Severus process, that uses the file name as metadata in-code.
    output:
        tuple val(meta), path("${params.sample_name}.${extension}"), path("${params.sample_name}.${extension}.${idx_extension}"), emit: alignment
    script:
    // samtools sort need extra threads. Specify these as N - 1 to avoid using too many cores.
    def sort_threads = params.ubam_sort_threads - 1
    """
    samtools bam2fq -@ ${params.ubam_bam2fq_threads} -T '*' ${reads} \
    | minimap2 -y -t ${params.ubam_map_threads} -ax map-ont --cap-kalloc 100m --cap-sw-mem 50m ${reference} - \
    | samtools sort -@ ${sort_threads} --write-index -o ${params.sample_name}.${extension}##idx##${params.sample_name}.${extension}.${idx_extension} -O ${extension} --reference ${reference} -
    """
}

// Check if the XAM header refer to the input reference.
process check_for_alignment {
    cpus 2
    input:
        tuple path(reference), path(ref_idx)
        tuple val(meta), path(xam), path(xam_idx)
    output:
        tuple env(to_align), val(meta), path(xam), path(xam_idx)
    script:
        """
        to_align=0
        workflow-glue check_sq_ref --xam ${xam} --ref ${reference} || to_align=\$?

        # Count SQ lines to help determine if this is unaligned BAM/CRAM later
        # permit grep to exit 1 if the count is zero, otherwise blow up here
        xam_sq_len=\$(samtools view -H ${xam} | { grep -c '^@SQ' || [[ \$? == 1 ]]; })

        # Allow EX_OK and EX_DATAERR, otherwise explode
        if [ \$to_align -ne 0 ] && [ \$to_align -ne 65 ]; then
            exit 1
        fi
        """
}


// Create ingress workflow, wrapping functions from `ingress.nf` and
// performing additional processings.
workflow ingress {
    take:
        ref_file
        ref_idx_file
        bam_file_fp
    main:
        // load bam as channel
        // We do not want to perform statistics here as we will do them downstream.
        // We also want to keep all unaligned reads.
        ingressed_bam = xam_ingress([
            "input":bam_file_fp,
            "sample":params.sample_name,
            "sample_sheet":null,
            "analyse_unclassified":true,
            "keep_unaligned": true,
            "stats": false,
            "watch_path": false
        ])
        // Check that we have a single BAM/folder with BAMs in it.
        // by counting how many entries are in the channel.
        // If there are more than 1, then throw an error.
        ingressed_bam
            .count()
            .subscribe { int n_samples -> 
                if (n_samples > 1){
                    error "Too many samples found: (${n_samples}) in ${bam_file_fp}.\nPlease, ensure you provide a single folder with all the BAM files for a single individual."
                }
            }

        // Prepare reference channel
        check_ref = ref_file.combine(ref_idx_file) // don't wait for cram_cache to perform check_for_alignment
        
        // Index the input BAM, and then check if the header matches the reference.
        // Add also if it is a CRAM (for downstream compatibility) and move if they need realignment
        // to meta.
        checked_bam = check_for_alignment(
                check_ref,
                ingressed_bam.map{ it - null }
            ) | 
            map{ to_align, meta, xam, xai ->
                [meta + [is_cram: xam.name.endsWith('.cram'), to_align: to_align != '0'], xam, xai]
            }
        // fork BAMs into to_align and noalign subchannels
        checked_bam.branch {
            meta, xam, xai -> 
            to_align: meta.is_unaligned || meta.to_align
            noalign: true
        }.set{alignment_fork}

        // If SVs are requested, create BAM to avoid issues in input definition.
        def extensions = params.sv ? ['bam', 'bai'] : ['cram', 'crai']
        // call minimap on bams that require (re)alignment
        // then map the result of minimap2_ubam to the canonical (reads, index, meta) tuple
        new_mapped_bams = minimap2_ubam(ref_file, alignment_fork.to_align, extensions).map{
            // map newly aligned bam to (xam_path, xam_index, xam_meta) tuple
            // setting the meta.is_cram to true because the bam was (re)aligned
            meta, xam, xai -> 
            [meta + [is_cram: true], xam, xai]
        }

        // mix to_align and noalign forks back to canonical bam_channel with (reads, reads_idx, meta) format
        bam_channel = alignment_fork.noalign.mix(new_mapped_bams)

    emit:
        bam_channel
}
