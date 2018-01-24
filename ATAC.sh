#!/bin/bash
#####################################
# Usage:	$1=reads1/file/to/path	#
#			$2=reads2/file/to/path	#
#			$3=output_prefix			#
#####################################

# path to reads
READS1=$1
READS2=$2
NAME=$3
picard=/home/quanyi/app/picard.jar
mkdir logs
mkdir fastqc
mkdir macs2 

# fastqc control
fastqc -f fastq -o fastqc $1 
fastqc -f fastq -o fastqc $2

# cutadapt to trim adaptors
cutadapt -f fastq -m 30 -a CTGTCTCTTATACACATCT -A CTGTCTCTTATACACATCT -g AGATGTGTATAAGAGACAG -G AGATGTGTATAAGAGACAG -o $3_R1_trimmed.gz -p $3_R2_trimmed.gz $1 $2 > ./logs/$3_cutadapt.log

# bowtie2 aligment #up to: 4 aligment/insert 2000bp
bowtie2 -k 2 -X 2000 --local --mm -p 6 -x $bowtie2index_hg19 -1 $3_R1_trimmed.gz -2 $3_R2_trimmed.gz -S $3.sam

echo 'Bowtie2 mapping summary:' > ./logs/$3_align.log
tail -n 15 nohup.out >> ./logs/$3_align.log

# samtools to BAM/sort
samtools view -b -@ 6 $3.sam -o $3.bam

samtools sort -@ 6 $3.bam -o $3_srt.bam

# picard mark duplaicates
java -jar $picard MarkDuplicates INPUT=$3_srt.bam OUTPUT=$3_mkdup.bam METRICS_FILE=./logs/$3_dup.log REMOVE_DUPLICATES=false

echo >> ./logs/$3_align.log
echo 'flagstat after markdup:' >> ./logs/$3_align.log
samtools flagstat $3_mkdup.bam >> ./logs/$3_align.log
samtools index $3_mkdup.bam 

# remove chrM reads
samtools idxstats $3_mkdup.bam | cut -f 1 |grep -v M | xargs samtools view -b -@ 6 -o $3_chrM.bam $3_mkdup.bam
samtools index $3_chrM.bam

# remove unpaired/unmapped/duplicates/not primary alignments
samtools view -f 2 -F 1804 -b -@ 6 -o $3_filtered.bam $3_chrM.bam

echo >> ./logs/$3_align.log
echo 'flagstat after filter:' >> ./logs/$3_align.log
samtools flagstat $3_filtered.bam >> ./logs/$3_align.log

# convert BAM to bigwig file
#create SE bed from bam
bamToBed -i $3_filtered.bam -split > $3_se.bed

#create plus and minus strand bedgraph
cat $3_se.bed | sort -k1,1 | bedItemOverlapCount hg19 -chromSize=$len_hg19 stdin | sort -k1,1 -k2,2n > $3.bedGraph

bedGraphToBigWig $3.bedGraph $len_hg19 $3_bam.bw

# Tn5 shifting
samtools sort -n -@ 6 -o $3_pe.bam $3_filtered.bam
bamToBed -bedpe -i $3_pe.bam > $3_pe.bed

awk -v OFS="\t" '{if($9=="+"){print $1,$2+4,$6+4}else if($9=="-"){if($2>=5){print $1,$2-5,$6-5}else if($6>5){print $1,0,$6-5}}}' $3_pe.bed > $3_shift.bed

# macs2 call broad peaks
cd macs2
macs2 callpeak -t ../$3_shift.bed -g hs -n $3 -f BEDPE --keep-dup all --broad -B --SPMR 

mv $3_control_lambda.bdg $3_control_lambda_SPMR.bdg
mv $3_treat_pileup.bdg $3_treat_pileup_SPMR.bdg
mv $3_peaks.xls $3_broad.xls

# convert bdg to bigwig file # see macs2 doc
bedGraph2bigwig.sh $3_treat_pileup_SPMR.bdg $len_hg19

# macs2 call narrow peaks
macs2 callpeak -t ../$3_shift.bed -g hs -n $3 -f BEDPE -B --keep-dup all

mv $3_peaks.xls $3_narrow.xls

# Blacklist filtering
intersectBed -v -a $3_peaks.broadPeak -b $bklt_hg19 > $3_broad_filtered.bed
intersectBed -v -a $3_peaks.narrowPeak -b $bklt_hg19 > $3_narrow_filtered.bed

# clean
gzip *.bdg
cd ..
rm $3.sam $3.bam $3_srt.bam $3_chrM.bam $3_chrM.bam.bai $3_R1_trimmed.gz $3_R2_trimmed.gz $3_pe.bam $3_pe.bed $3.bedGraph
