#!/usr/bin/env perl

use strict;
use warnings;
use Carp;
use Getopt::Long qw(:config posix_default no_ignore_case bundling pass_through);
use FindBin;
use lib ("$FindBin::Bin/../PerlLib");
use Fasta_reader;
use Nuc_translator;
use PWM;

my $usage = <<__EOUSAGE__;

#####################################################################
#
#  --transcripts <string>     target transcripts fasta file
#
#  --train_gff3 <string>      longest_orfs.cds.best_candidates.gff3
#
#  --out_prefix <string>      output prefix for pwm and feature sequences
#
## Optional
#
#  --pwm_left <int>           default: 10
#
#  --pwm_right <int>          default: 10         
#
#
#####################################################################


__EOUSAGE__

    ;


my $help_flag;
my $transcripts_file;
my $train_gff3_file;
my $pwm_left = 10;
my $pwm_right = 10;
my $out_prefix = undef;


&GetOptions ( 'h' => \$help_flag, 
              'transcripts=s' => \$transcripts_file,
              'train_gff3=s' => \$train_gff3_file,
              'pwm_left=i' => \$pwm_left,
              'pwm_right=i' => \$pwm_right,
              'out_prefix=s' => \$out_prefix,
    
    );

if ($help_flag) {
    die $usage;
}

unless ($transcripts_file && $train_gff3_file && $out_prefix) {
    die $usage;
}

my $pwm_length = $pwm_left + 3 + $pwm_right;


main: {

    my $fasta_reader = new Fasta_reader($transcripts_file);

    my %seqs = $fasta_reader->retrieve_all_seqs_hash();

    my @starts = &parse_starts($train_gff3_file);



    my $pwm_plus = new PWM();
    my $pwm_minus = new PWM();
    
    
    my $features_file = "$out_prefix.features";
    open (my $ofh_features, ">$features_file") or die "Error, cannot write to $features_file";
        
    foreach my $start_info (@starts) {
        my ($transcript_acc, $start_coord, $orient) = @$start_info;
        
        my $transcript_seq = $seqs{$transcript_acc};

        if ($orient eq '-') {
            # convert info to (+) strand
            $transcript_seq = &reverse_complement($transcript_seq);
            $start_coord = length($transcript_seq) - $start_coord + 1;
        }

        my $start_codon = substr($transcript_seq, $start_coord - 1, 3);
        if ($start_codon ne "ATG") { next; }
                
        
        my @trans_chars = split(//, uc $transcript_seq);

        my $feature_seq = &get_feature_seq(\@trans_chars, $start_coord - 1);

        if ($feature_seq) {
            
            print $ofh_features join("\t", $feature_seq, $transcript_acc) . "\n";
            
            $pwm_plus->add_feature_seq_to_pwm($feature_seq);
        }
        
        ######################################
        ## contribute rest to the negative set.
        $transcript_seq = substr($transcript_seq, $start_coord + 1);
        
        &add_all_starts_to_pwm($pwm_minus, $transcript_seq);
        
    }

    # build and write plus model
    $pwm_plus->build_pwm();
    
    my $pwm_plus_file = "$out_prefix.+.pwm";
    $pwm_plus->write_pwm_file($pwm_plus_file);

    # build and write minus model
    $pwm_minus->build_pwm();

    my $pwm_minus_file = "$out_prefix.-.pwm";
    $pwm_minus->write_pwm_file($pwm_minus_file);

        
    exit(0);
    

}


####
sub get_feature_seq {
    my ($seq_aref, $start_coord) = @_;
    
    my $begin_pwm = $start_coord - $pwm_left;
    my $end_pwm = $begin_pwm + $pwm_length - 1;
        
    if ($begin_pwm < 0 || $end_pwm > $#$seq_aref) {
        # out of bounds on sequence
        return(undef);
    }
    
    
    my $feature_seq = "";
    for (my $i = $begin_pwm; $i <= $end_pwm; $i++) {
        my $char = $seq_aref->[$i];
        $feature_seq .= $char;
    }
    
    return($feature_seq);
}



####
sub add_all_starts_to_pwm {
    my ($pwm_obj, $sequence) = @_;

    my @seqarray = split(//, $sequence);
    
    my @candidates;
    
    while ($sequence =~ /(ATG)/g) {
        
        my $pos_start = $-[0];
        push (@candidates, $pos_start);
    }

    foreach my $start_pos (@candidates) {
        my $feature_seq = &get_feature_seq(\@seqarray, $start_pos);
        
        if ($feature_seq) {
            $pwm_obj->add_feature_seq_to_pwm($feature_seq);
        }
    }

    return;
}
    


####
sub parse_starts {
    my ($gff3_file) = @_;

    my @starts;
    
    open(my $fh, $gff3_file) or die "Error cannot open file $gff3_file";
    while (<$fh>) {
        unless (/\w/) { next; }
        if (/^\#/) { next; }
        chomp;
        my @x = split(/\t/);

        my $transcript = $x[0];
        
        my $feat_type = $x[2];
        
        my $lend = $x[3];
        my $rend = $x[4];
        my $orient = $x[6];

        my $info = $x[8];

        if ($feat_type eq "CDS") {

            if ($orient eq '+') {
                push (@starts, [$transcript, $lend, $orient]);
            }
            else {
                push (@starts, [$transcript, $rend, $orient]);
            }
        }

    }
    close $fh;

    return(@starts);
}


####
sub convert_counts_to_prob_vals {
    my (@vals) = @_;

    my $index = shift @vals;
    
    my $sum = 0;
    foreach my $val (@vals) {
        $sum += $val;
    }

    my @probs = ($index);
    foreach my $val (@vals) {
        my $prob = sprintf("%.3f", $val / $sum);
        
        push (@probs, $prob);
    }

    return(@probs);
}
