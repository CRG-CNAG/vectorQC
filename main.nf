#!/usr/bin/env nextflow


/* 
 * Copyright (c) 2018, Centre for Genomic Regulation (CRG) 
 * 
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. 
 */


/*
===========================================================
vectorQC pipeline for Bioinformatics Core @ CRG

 @authors
 Luca Cozzuto <lucacozzuto@gmail.com>
=========================================================== 
*/

version = '0.1'

/*
 * Input parameters: read pairs, db fasta file, etc
 */

params.help            = false
params.resume          = false


log.info """
Biocore@CRG VectorQC - N F  ~  version ${version}

╔╗ ┬┌─┐┌─┐┌─┐┬─┐┌─┐╔═╗╦═╗╔═╗  ┬  ┬┌─┐┌─┐┌┬┐┌─┐┬─┐╔═╗ ╔═╗
╠╩╗││ ││  │ │├┬┘├┤ ║  ╠╦╝║ ╦  └┐┌┘├┤ │   │ │ │├┬┘║═╬╗║  
╚═╝┴└─┘└─┘└─┘┴└─└─┘╚═╝╩╚═╚═╝   └┘ └─┘└─┘ ┴ └─┘┴└─╚═╝╚╚═╝
                                                                                       
====================================================
reads                       : ${params.reads}
inserts                     : ${params.inserts}
references                  : ${params.references}
features                    : ${params.features}
commonenz (common enzymes)  : ${params.commonenz}
adapter                     : ${params.adapter}
minsize (after filtering)   : ${params.minsize}
trimquality                 : ${params.trimquality}
meanquality                 : ${params.meanquality}
merge (merge read pairs)    : ${params.merge}
output (output folder)      : ${params.output}
email for notification      : ${params.email}

"""

if (params.help) {
    log.info 'This is the Biocore\'s vectorQC pipeline'
    log.info '\n'
    exit 1
}
if (params.resume) exit 1, "Are you making the classical --resume typo? Be careful!!!! ;)"

featuresdb = file(params.features)
if( !featuresdb.exists() ) exit 1, "Missing feature file: ${params.features}"

commonenz = file(params.commonenz)
if( !commonenz.exists() ) exit 1, "Missing common enzyme file: ${params.commonenz}"

tooldb = file("$baseDir/conf_tools.txt")
if( !tooldb.exists() ) exit 1, "Missing tooldb: conf_tools.txt"

multiconfig = file("$baseDir/config.yaml")
if( !multiconfig.exists() ) exit 1, "Missing config file config.yaml"

logo_vectorQC = file("$baseDir/plots/logo_vectorQC_small.png")

inserts_file = file(params.inserts)


outputQC          = "${params.output}/QC"
outputAssembly    = "${params.output}/Assembly"
outputRefAssembly = "${params.output}/Refined_Assembly"
outputBlast       = "${params.output}/Blast"
outputRE          = "${params.output}/REsites"
outputPlot        = "${params.output}/Plots"
outputGBK         = "${params.output}/GenBank"
outputMultiQC     = "${params.output}/MultiQC"
outputVariants    = "${params.output}/Variants"
outputReport      = file("${outputMultiQC}/multiqc_report.html")


/*
 * move old multiQCreport in case it already exists 
 */
 
if( outputReport.exists() ) {
  log.info "Moving old report to multiqc_report.html multiqc_report.html.old"
  outputReport.moveTo("${outputMultiQC}/multiqc_report.html.old")
}

/*
 * Create channels for sequences data 
 */
 
Channel
    .fromFilePairs( params.reads)                                       
    .ifEmpty { error "Cannot find any reads matching: ${params.reads}" }
    .set { read_files_for_trimming}    

Channel
    .fromPath( params.reads )                                             
    .ifEmpty { error "Cannot find any reads matching: ${params.reads}" }
    .into {reads_for_fastqc; read_files_for_size} 

if( params.references == "" ) {
    log.info "Performing analysis without known references"
} else {
    Channel
       .fromFilePairs( params.references , size: 1)                                      
       .ifEmpty { error "Cannot find any reference matching: ${params.references}" }
       .set {references} 

    log.info "Performing analysis using known references"  
}
/*
 * Extract read length 
*/
process getReadLength {
    input:
    file(single_read_pairs) from read_files_for_size.first()

    output:
    stdout into (read_length_for_merging)

	script:
	def qc = new QualityChecker(input:single_read_pairs)
	qc.getReadSize()
}

/*
 * Run FastQC on raw data
 */
process raw_fastqc {
    tag "$read"
    publishDir outputQC, mode: 'copy', pattern: '*fastqc*'

    afterScript 'mv *_fastqc.zip `basename *_fastqc.zip _fastqc.zip`_raw_fastqc.zip'

    input:
    file(read) from reads_for_fastqc

    output:
    file("*_fastqc.zip") into raw_fastqc_files

    script:
    def qc = new QualityChecker(input:read, cpus:task.cpus)
    qc.fastqc()
}

/*
 * Trim reads with skewer for removing the RNA primer at 3p
 */ 
 
process trimReads {
    tag "$pair_id"
    afterScript 'mv *-trimmed-pair1* `echo *-trimmed-pair1* | sed s/\\-trimmed\\-pair1/_1_filt/g`; mv *-trimmed-pair2* `echo *-trimmed-pair2* | sed s/\\-trimmed\\-pair2/_2_filt/g`'
         
    input:
    set pair_id, file(reads) from (read_files_for_trimming)

    output:
    set pair_id, file("*_filt.fastq.gz") into filtered_reads_for_assembly
    file("*_filt.fastq.gz") into filtered_read_for_QC
    file("*trimmed.log") into logTrimming_for_QC

    script:    
    def trimmer = new Trimmer(reads:reads, extrapars:"-Q ${params.meanquality} -q ${params.trimquality} -x ${params.adapter}", id:pair_id, min_read_size:params.minsize, cpus:task.cpus)
    trimmer.trimWithSkewer()
}

/*
 * FastQC
 */ 
process trimmedQC {
    tag "$filtered_read"
    publishDir outputQC, mode: 'copy', pattern: '*fastqc*'

    //afterScript 'mv *_fastqc.zip `basename *_fastqc.zip _fastqc.zip`_filt_fastqc.zip'

    input:
    file(filtered_read) from filtered_read_for_QC.flatten()

    output:
    file("*_fastqc.zip") into trimmed_fastqc_files

    script:
    def qc = new QualityChecker(input:filtered_read, cpus:task.cpus)
    qc.fastqc()
}

/*
 * Run assembly of input sequence
 */
 
process assemble {
    tag "$pair_id"
    publishDir outputAssembly, mode: 'copy', pattern: '*_assembly.fa'

    label 'big_mem_cpus'

    input:
    set pair_id, file(readsA), file(readsB) from  filtered_reads_for_assembly.flatten().collate( 3 )
    val read_size from read_length_for_merging.map { it.trim().toInteger() }

    output:
    set pair_id, file("${pair_id}_assembly.fa"), file("${pair_id}/spades.log") into scaffold_for_evaluation

    script:

    if( params.merge)
    """
       flash -t ${task.cpus} -o joint_reads -m 50 -M ${read_size} ${readsA} ${readsB}
       spades.py --phred-offset 33 --cov-cutoff auto --careful -s joint_reads.extendedFrags.fastq -o ${pair_id} -t ${task.cpus} -m ${task.memory.giga} 
       cp ${pair_id}/scaffolds.fasta ${pair_id}_assembly.fa
    """
    else 
    """
       spades.py --phred-offset 33 --cov-cutoff auto --careful --pe1-1 ${readsA} --pe1-2 ${readsB} -o ${pair_id} -t ${task.cpus} -m ${task.memory.giga} 
       cp ${pair_id}/scaffolds.fasta ${pair_id}_assembly.fa
    """
}


/*
 * evaluate assembly
 */
 
 process evaluateAssembly {
   publishDir outputRefAssembly, mode: 'copy', pattern: '*_assembly_ev.fa'
   tag "$pair_id"
    
    echo true
    label 'big_mem_cpus'

    input:
    set pair_id, file(scaffolds), file(log_assembly) from  scaffold_for_evaluation
    
    output:
    set pair_id, file("${pair_id}_assembly_ev.fa") into scaffold_file_for_blast, scaffold_file_for_re, scaffold_file_for_parsing, scaffold_file_for_variants
    set pair_id, file("${pair_id}_assembly_ev.fa.log") into log_assembly_for_report  

    script:
    """
        kmer=`grep "Used k-mer sizes" ${log_assembly} | awk '{print \$NF}'`
        evaluateAssembly.py -i ${scaffolds} -o ${pair_id}_assembly_ev.fa -n ${pair_id} -k \$kmer
    """
}

/*
 * joine db files
 */
process prepareDB {
    tag "$params.inserts"

    when:
    params.inserts

    input:
    file(features_file) from featuresdb
    file(inserts_file)
    
    output:
    file("whole_db_pipe.fasta") into whole_db_fasta
    
    """
        parseInserts.py -i ${inserts_file} -o  whole_db_pipe.fasta
        if [ `echo ${features_file} | grep ".gz"` ]; then 
            zcat ${features_file} >> whole_db_pipe.fasta
        else 
            cat zcat ${features_file} >> whole_db_pipe.fasta
        fi
    """

}


/*
 * Make blast db
 */
 
process makeBlastDB {
    tag "$features_file"
    
    input:
    file(features_file) from (params.inserts ? whole_db_fasta : featuresdb)

    output:
    set "blast_db.fasta", file("blast_db.fasta*") into blastdb_files

    script:
    def aligner = new NGSaligner(reference_file:features_file, index:"blast_db.fasta", dbtype:"nucl")
    aligner.doIndexing("blast")
}

/*
 * Run blast
 */
 
process runBlast {
    tag "$pair_id"
    publishDir outputBlast

    label 'big_mem_cpus'

    input:
    set blastname, file(blastdbs) from blastdb_files
    set pair_id, file(scaffold_file) from scaffold_file_for_blast

    output:
    set pair_id, file("${pair_id}.blastout") into blast_out_for_plot

    script:
    def aligner = new NGSaligner(reads:scaffold_file, output:"${pair_id}.blastout", index:"blast_db.fasta", cpus:task.cpus, extrapars:"-outfmt 6 -word_size 11")
    aligner.doAlignment("blast")
}


/*
 * Run restrict 
 */
 
process runRestrict {
    tag "$pair_id"
    publishDir outputRE

    input:
    set pair_id, file(scaffold_file) from scaffold_file_for_re
    file(commonenz)

    output:
    set pair_id, file("${pair_id}.restrict") into restric_file_for_graph

    script:
    """
        restrict -sequence ${scaffold_file} -outfile ${pair_id}.restrict -single -auto -enzymes @${commonenz} -plasmid
    """
}


/*
 * make plots
 */
 
process makePlot {
    tag "$pair_id"
    publishDir outputPlot, mode: 'copy', pattern: '*.svg' 
    publishDir outputGBK, mode: 'copy', pattern: '*.gbk'

    input:
    set pair_id, file(blastout), file(resites), file(scaffold) from blast_out_for_plot.join(restric_file_for_graph).join(scaffold_file_for_parsing)

    output:
    set pair_id, file("${pair_id}.log") into log_insert_for_report  
    file("${pair_id}.svg") 
    file("${pair_id}.gbk") 

    script:
    """
        parse.py -n ${pair_id} -b ${blastout} -f ${scaffold} -o ${pair_id} -r ${resites}
        \$CGVIEW -i ${pair_id}.xml  -x true -f svg -o ${pair_id}.svg
    """
}

/*
 * Run variant calling 
 */
 
process callVariants {
    tag "$pair_id"
    publishDir outputVariants

    when: 
    references
    
    input:
    set pair_id, file(scaffold_file), file (reference_file) from scaffold_file_for_variants.join(references)

    output:
    file("${pair_id}.vcf")

    script:
    """
        bwa index ${reference_file}
		bwa mem ${reference_file} ${scaffold_file} | samtools view -Sb - > aln.bam
		samtools sort aln.bam -o ${pair_id}.bam 
		rm aln.bam
		bcftools mpileup -Ou -f ${reference_file} ${pair_id}.bam  | bcftools call --ploidy 1 -mv -Ov -o ${pair_id}.vcf
    """
}


/*
 * Join logs for making a report. 
 */
 
process makePipeReport {
    tag "$pair_id"

    input:
    set pair_id, file(insert), file(assembly) from log_insert_for_report.join(log_assembly_for_report)

    output:
    file("${pair_id}_repo.txt") into pipe_report_for_join
        
    script:
    """
        paste ${assembly} ${insert} > ${pair_id}_repo.txt
    """
}

/*
 * Make section of multiQC report about the pipeline results. 
 */
process makePipeMultiQCReport {
    input:
    file("report*") from pipe_report_for_join.collect()

    output:
    file("vectorQC_mqc.txt") into pipe_report_for_multiQC 
        
    script:
    """
    echo "# plot_type: 'table'
# section_name: 'vectorQC'
# description: 'Results of the vectorQC pipeline. Number of contigs found, total size and inserted genes found'
# pconfig:
#     namespace: 'vectorQC'
# headers:
#     col1:
#         title: 'Sample'
#     col2:
#          title: '# of scaffolds'             
#          format: '{:,.0f}'
#     col3:
#          title: 'Size'
#          format: '{:,.0f}'
#     col4:
#          title: 'Insert(s) found'
Sample    col2    col3    col4
" > vectorQC_mqc.txt
        cat report* >> vectorQC_mqc.txt
    """
}

/*
 * Make section of multiQC report about the tools used. 
 */
 
process tool_report {

    input:
    file(tooldb)

    output:
    file("tools_mqc.txt") into tool_report_for_multiQC 
        
    script:
    """
         make_tool_desc_for_multiqc.pl -c ${tooldb} -l fastqc,skewer,spades,blast,cgview,emboss,samtools,bcftools,bwa > tools_mqc.txt
    """
}

/*
 * multiQC report
 */
process multiQC {
    publishDir outputMultiQC, mode: 'copy'

    input:
    file ("*") from raw_fastqc_files.mix(logTrimming_for_QC,trimmed_fastqc_files).flatten().collect()
    file 'pre_config.yaml.txt' from multiconfig
    file (tool_report_for_multiQC)
    file (pipe_report_for_multiQC)
    file (logo_vectorQC)

    output:
    file("multiqc_report.html") into multiQC 
    
    script:
    def reporter = new Reporter(title:"VectorQC screening", application:"Mi-seq", subtitle:"", id:"vectors", email:params.email, config_file:"pre_config.yaml.txt")
    reporter.makeMultiQCreport()
}

if (params.help) {
    log.info 'This is the Biocore\'s vectorQC pipeline'
    log.info '\n'
    exit 1
}

/*
 * Mail notification
 */

if (params.email == "yourmail@yourdomain" || params.email == "") { 
    log.info 'Skipping the email\n'
}
else {
    log.info "Sending the email to ${params.email}\n"

    workflow.onComplete {

    def msg = """\
        Pipeline execution summary
        ---------------------------
        Completed at: ${workflow.complete}
        Duration    : ${workflow.duration}
        Success     : ${workflow.success}
        workDir     : ${workflow.workDir}
        exit status : ${workflow.exitStatus}
        Error report: ${workflow.errorReport ?: '-'}
        """
        .stripIndent()

        sendMail(to: params.email, subject: "VectorQC execution", body: msg,  attach: "${outputMultiQC}/multiqc_report.html")
    }
}

workflow.onComplete {
    println "Pipeline BIOCORE@CRG vectorQC completed at: $workflow.complete"
    println "Execution status: ${ workflow.success ? 'OK' : 'failed' }"
}

