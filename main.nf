params.input = "s3://aws-batch-genomics-shared/secondary-analysis/example-files/fastq"
params.reference = "s3://broad-references/hg38/v0/Homo_sapiens_assembly38.fasta"
params.sample_id = "NIST7035"
params.chromosomes = "chr21"

// this is used as the publishDir in a couple processes.
// users need to specify a bucket that they have write access to for outputs
// otherwise you will get Access Denied errors that will end up terminating the workflow
params.output = "NONE"

// nextflow script is based on Groovy, so all language constructs therein
// can be used in workflow definitions.
// here is a mapping to define the specific container versions for the tools
// in the pipeline.
def containers = [
  bwa: "biocontainers/bwa:v0.7.15_cv4",
  samtools: "biocontainers/samtools:v1.7.0_cv4",
  bcftools: "biocontainers/bcftools:v1.5_cv3"
]

sample_id = params.sample_id
output_dir = "${params.output}/${params.sample_id}"


ref_name = file(params.reference).name
ref_indices = Channel
  .fromPath("${params.reference}*")
  .toList()

reads = Channel
  .fromPath("${params.input}/${sample_id}_*{1,2}*{fastq.gz}")
  .toList()


chromosomes = Channel.fromList( params.chromosomes.tokenize(',') )

log.info """
script: ${workflow.scriptId}
session: ${workflow.sessionId}

sample-id: ${sample_id}
"""

process bwa_mem {
    container "${containers.bwa}"
    cpus 8
    memory "64 GB"

  input:
    file '*' from ref_indices
    file '*' from reads
  
  output:
    file "${sample_id}.sam" into sam_file
  
  script:
  """
  bwa mem -t 16 -p \
        ${ref_name} \
        ${sample_id}_*1*.fastq.gz \
        > ${sample_id}.sam
  """
}


process samtools_sort {
    container "${containers.samtools}"
    cpus 8
    memory "32 GB"

    if (params.output != 'NONE') {
      publishDir "${output_dir}", enabled: params.output != 'NONE'
    }

  input:
    file "${sample_id}.sam" from sam_file
  
  output:
    file "${sample_id}.bam" into bam_file
  
  script:
  """
  samtools sort \
        -@ 16 \
        -o ${sample_id}.bam \
        ${sample_id}.sam
  """
}

process samtools_index {
    container "${containers.samtools}"
    cpus 8
    memory "32 GB"

    if (parames.output != 'NONE') {
      publishDir "${output_dir}", enabled: params.output != 'NONE'
    }

  input:
    file "${sample_id}.bam" from bam_file
  
  output:
    file "${sample_id}.bam.bai" into bai_file
  
  script:
  """
  samtools index \
        ${sample_id}.bam
  """
}

process bcftools_mpileup {
    container "${containers.bcftools}"
    cpus 8
    memory "32 GB"

  input:
    file "*" from ref_indices
    file "${sample_id}.bam" from bam_file
    file "${sample_id}.bai" from bai_file
    val chromosome from chromosomes

  output:
    file "${sample_id}.${chromosome}.mpileup.gz" into vcf_files
  
  script:
  """
  bcftools mpileup \
        --threads 16 \
        -Oz \
        -r ${chromosome} \
        -f ${ref_name} \
        ${sample_id}.bam \
        > ${sample_id}.${chromosome}.mpileup.gz
  """
}

process bcftools_call {
    container "${containers.bcftools}"
    cpus 8
    memory "32 GB"

    if (params.output != 'NONE') {
      publishDir "${output_dir}", enabled: params.output != 'NONE'
    }

  input:
    val chromosome from chromosomes
    file "${sample_id}.${chromosome}.mpileup.gz" from vcf_files

  output:
    file "${sample_id}.${chromosome}.vcf.gz"
  
  script:
  """
  bcftools call \
        -m \
        --threads 16 \
        -Oz \
        -t ${chromosome} \
        -o ${sample_id}.${chromosome}.vcf.gz \
        ${sample_id}.${chromosome}.mpileup.gz
  """
}


workflow.onError {
    println "Oops... Pipeline execution stopped with the following message: ${workflow.errorMessage}"
}

workflow.onComplete {
    println "Pipeline completed at: $workflow.complete"
    println "Execution status: ${ workflow.success ? 'OK' : 'failed' }"
}
