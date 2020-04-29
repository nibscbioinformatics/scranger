#!/usr/bin/env nextflow
/*
========================================================================================
                         nibscbioinformatics/scranger
========================================================================================
 nibscbioinformatics/scranger Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nibscbioinformatics/scranger
----------------------------------------------------------------------------------------
*/

// ############ PARAMS DEFAULTS ####################
params.cellranger_reference = 'GRCh38'



def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nibscbioinformatics/scranger --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                  Path to input sample TSV file
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Options:
      --cellranger_reference [str]    Name of the reference version to be used for transcriptome analysis.
                                      Available: GRCh38 (Homo sapiens), mm10 (Mus musculus). Default is GRCh38.

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Check if transcriptome exists in the config file
if (params.transcriptomes && params.cellranger_reference && !params.transcriptomes.containsKey(params.cellranger_reference)) {
    exit 1, "The provided transcriptome '${params.cellranger_reference}' is not available in the repository. Currently the available transcriptomes are ${params.transcriptomes.keySet().join(", ")}"
}


params.refpack = params.cellranger_reference ? params.transcriptomes[ params.cellranger_reference ].file ?: false : false
if (params.refpack) { ch_reference = Channel.value(file(params.refpack, checkIfExists: true)) }


// #############################
// ## DEFINE THE INPUTS

// samples metadata need to be specified in tabular format with the following information (per column)
// SAMPLE NAME (which goes into cell ranger)
// SAMPLE ID(s) again in cell ranger specification from fastq files for merging
// FASTQ FOLDER(s) where files with a name formatted to begin with the provided sample ID are present
// the file has to be tab separated because a coma is used to separate ids and folders

Channel
      .fromPath("${params.input}")
      .splitCsv(header: ['sampleID', 'fastqIDs', 'fastqLocs'], sep: '\t')
      .map{ row-> tuple(row.sampleID, row.fastqIDs, row.fastqLocs) }
      .set { metadata_ch }

  (metadata_ch, fastqc_pre_ch) = metadata_ch.into(2)

// #########################################
// ## PROCESS THE QUITE SPECIAL FORMAT REQUIRED
// ## BY CELLRANGER into a list of fastq to be used
// ## for the FastQC process

// fastqc_files_ch = Channel.empty()
allData = fastqc_pre_ch.collect()
// allData.each() {
//   data ->
//   def sampleID = data[0]
//   def fastqIDs = data[1]
//   def fastqLocs = data[3]
//   fastqLocs.splitCsv().each() {
//     fastq ->
//     tuple(sampleID, fastq) into fastqc_files_ch
//   }
// }

fastqc_files_ch = Channel.fromList(
  allData.each() {
    data ->
    def sampleID = data[0]
    def fastqIDs = data[1]
    def fastqLocs = data[3]
    fastqLocs.splitCsv().each() {
      fastq ->
      return [sampleID, fastq]
    }
  }
  )



// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)



// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nibscbioinformatics-scranger-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nibscbioinformatics/scranger Workflow Summary'
    section_href: 'https://github.com/nibscbioinformatics/scranger'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc/${sampleID}", mode: 'copy',
        saveAs: { filename ->
                      filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                }

    input:
    set val(sampleID), file(reads) from fastqc_files_ch

    output:
    file "*_fastqc.{zip,html}" into ch_fastqc_results

    script:
    """
    fastqc --quiet --threads $task.cpus $reads
    """
}

/*
 * STEP 2 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file (multiqc_config) from ch_multiqc_config
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc -f $rtitle $rfilename $custom_config_file .
    """
}




/*
############################################
###### EXISTING PIPELINE ###################
############################################
*/



// This first process uses the CellRanger suite in order to process the reads per sample
// collapse the UMIs and identify cell barcodes
// creating the genome alingments as well as the expression counts


process unpackReference {

  tag "unpacking reference"
  label "process_small"

  input:
  file(reference) from ch_reference

  output:
  path("${reference.simpleName}", type: 'dir') into ch_reference_folder

  script:
  """
  tar -xvzf ${reference}
  """

}


process CellRangerCount {

  tag "counting"
  label "process_high"
  label "process_long"

  publishDir "$params.outdir/${sampleName}/counts/", mode: 'copy',
      saveAs: { filename ->
                    "${sampleName}_${filename}"
              }

  input:
  path(referenceFolder) from ch_reference_folder
  set sampleName, fastqIDs, fastqLocs from metadata_ch


  output:
  tuple val("$sampleName"), file("metrics_summary.csv") into cellranger_summary_ch
  tuple val("$sampleName"), file("*.gz") into count_files_ch
  tuple val("$sampleName"), file("possorted_genome_bam.bam"), file("possorted_genome_bam.bam.bai") into alignments_ch
  tuple val("$sampleName"), val("$PWD") into processed_samples

  script:

  """
  cellranger count \
  --id=${sampleName} \
  --sample=${fastqIDs} \
  --fastqs=${fastqLocs} \
  --transcriptome=${referenceFolder}

  mv ${sampleName}/outs/metrics_summary.csv .
  mv "${sampleName}/outs/filtered_feature_bc_matrix/*.gz .
  mv ${sampleName}/outs/possorted_genome_bam.bam .
  mv $sampleName/outs/possorted_genome_bam.bam.bai .
  """

}


// Next we use the Seurat package in order to aggregage the previously generated counts


process Aggregate {

  tag "aggregate"
  cpus 2
  queue 'WORK'
  time '24h'
  memory '20 GB'

  publishDir "$params.outdir/aggregated", mode: 'copy'

  input:
  set sampleNamesList, countFoldersList from processed_samples.collect()

  output:
  file('aggregated_object.RData') into (aggregate_filtered_ch, aggregate_unfiltered_ch)

  script:
  sampleNames = sampleNamesList.join(",")
  countFolders = countFoldersList.join(",")

  """
  Rscript -e "workdir<-getwd()
  rmarkdown::render('$HOME/CODE/core/workflows/singlecellrna/seurat_scripts/aggregate.Rmd',
    params = list(
      sample_paths = \\\"$countFolders\\\",
      sample_names = \\\"$sampleNames\\\",
      output_path = workdir),
      knit_root_dir=workdir,
      output_dir=workdir)"
  """

}


// A minimum set of exploratory analyses are then run on unfiltered and filtered data

process ExploreUnfiltered {

  tag "exploreUnfiltered"
  label "process_medium"

  publishDir "$params.outdir/reports", mode: 'copy'

  input:
  file(aggregatedObj) from aggregate_unfiltered_ch

  output:
  file('analyse_unfiltered.html') into unfiltered_report_ch
  file('aggregated_object_analyzed_unfiltered.RData') into unfiltered_object_ch

  script:
  """
  Rscript -e "workdir<-getwd()
    rmarkdown::render('$HOME/CODE/core/workflows/singlecellrna/seurat_scripts/analyse_unfiltered.Rmd',
    params = list(input_path = \\\"$aggregatedObj\\\"),
    knit_root_dir=workdir,
    output_dir=workdir)"
  """
}


process ExploreFiltered {

  tag "exploreFiltered"
  label "process_medium"

  publishDir "$params.outdir/reports", mode: 'copy'

  input:
  file(aggregatedObj) from aggregate_filtered_ch

  output:
  file('analyse_filtered.html') into filtered_report_ch
  file('aggregated_object_analyzed_filtered.RData') into filtered_object_ch

  script:
  """
  Rscript -e "workdir<-getwd()
    rmarkdown::render('$HOME/CODE/core/workflows/singlecellrna/seurat_scripts/analyse_filtered.Rmd',
    params = list(input_path = \\\"$aggregatedObj\\\"),
    knit_root_dir=workdir,
    output_dir=workdir)"
  """
}



/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nibscbioinformatics/scranger] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nibscbioinformatics/scranger] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nibscbioinformatics/scranger] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nibscbioinformatics/scranger] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nibscbioinformatics/scranger] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nibscbioinformatics/scranger] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nibscbioinformatics/scranger]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nibscbioinformatics/scranger]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nibscbioinformatics/scranger v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
