#! /usr/bin/perl -w
#
# Copyright (C) 2008-2016 Alexis Bienvenue <paamc@passoire.fr>
#
# This file is part of Auto-Multiple-Choice
#
# Auto-Multiple-Choice is free software: you can redistribute it
# and/or modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version 2 of
# the License, or (at your option) any later version.
#
# Auto-Multiple-Choice is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Auto-Multiple-Choice.  If not, see
# <http://www.gnu.org/licenses/>.
use strict;
use warnings;
 
use Getopt::Long;

use Gtk2 ;

#use Glib::Object::Introspection;
use XML::Simple;
use IO::File;
use IO::Select;
use POSIX qw/strftime/;
use Time::Local;
use Cwd;
use File::Spec::Functions qw/splitpath catpath splitdir catdir catfile rel2abs tmpdir/;
use File::Temp qw/ tempfile tempdir /;
use File::Copy;
use File::Path qw/remove_tree/;
use File::Find;
#use Archive::Tar;
#use Archive::Tar::File;
use Encode;
use Unicode::Normalize;
use I18N::Langinfo qw(langinfo CODESET);
use Locale::Language;
use Text::ParseWords;

use Module::Load;
use Module::Load::Conditional qw/check_install/;

#use AMC::Path;
use AMC::Basic;
#use AMC::State;
#use AMC::Data;
#use AMC::DataModule::capture ':zone';
#use AMC::DataModule::report ':const';
#use AMC::Scoring;
#use AMC::Gui::Prefs;
#use AMC::Gui::Manuel;
#use AMC::Gui::Association;
#use AMC::Gui::Commande;
#use AMC::Gui::Notes;
#use AMC::Gui::Zooms;
#use AMC::FileMonitor;
#use AMC::Gui::WindowSize;

use utf8;


use constant {
    DOC_TITRE => 0,
    DOC_MAJ => 1,

    MEP_PAGE => 0,
    MEP_ID => 1,
    MEP_MAJ => 2,

    DIAG_ID => 0,
    DIAG_ID_BACK => 1,
    DIAG_MAJ => 2,
    DIAG_EQM => 3,
    DIAG_EQM_BACK => 4,
    DIAG_DELTA => 5,
    DIAG_DELTA_BACK => 6,
    DIAG_ID_STUDENT => 7,
    DIAG_ID_PAGE => 8,
    DIAG_ID_COPY => 9,

    INCONNU_FILE => 0,
    INCONNU_SCAN => 1,
    INCONNU_TIME => 2,
    INCONNU_TIME_N => 3,
    INCONNU_PREPROC => 4,

    PROJ_NOM => 0,
    PROJ_ICO => 1,

    MODEL_NOM => 0,
    MODEL_PATH => 1,
    MODEL_DESC => 2,

    COPIE_N => 0,

    TEMPLATE_FILES_PATH => 0,
    TEMPLATE_FILES_FILE => 1,

    EMAILS_SC => 0,
    EMAILS_NAME => 1,
    EMAILS_EMAIL => 2,
    EMAILS_ID => 3,
    EMAILS_STATUS => 4,

    ATTACHMENTS_FILE => 0,
    ATTACHMENTS_NAME => 1,
    ATTACHMENTS_FOREGROUND => 2,
};



use_gettext;
use_amc_plugins();

POSIX::setlocale(&POSIX::LC_NUMERIC,"C");

my $debug=0;
my $debug_file='';
my $show_secret= 0;
my $generate_secret= 0;
my $home_dir = '';
my $api_url = '/';
my $project_dir='';
my $profile='';
GetOptions(
       "show-secret!"=>\$show_secret,
       "generate-secret!"=>\$generate_secret,
       "home-dir=s" => \$home_dir,
          );

$project_dir=Cwd::realpath($project_dir) if($project_dir);


if ($home_dir eq "") {
    $home_dir = promptUser("Home directory:",cwd);
}



my $o_file='';
my $o_dir = $home_dir;


# Gets system encoding
my $encodage_systeme=langinfo(CODESET());
$encodage_systeme='UTF-8' if(!$encodage_systeme);

sub hex_color {
    my $s=shift;
    return(Gtk2::Gdk::Color->parse($s)->to_string());
}

# Default general options, to be used when not set in the main options
# file

my %o_defaut=('pdf_viewer'=>['commande',
			     'evince','acroread','gpdf','okular','xpdf',
			     ],
	      'img_viewer'=>['commande',
			     'eog','ristretto','gpicview','mirage','gwenview',
			     ],
	      'csv_viewer'=>['commande',
			     'gnumeric','kspread','libreoffice','localc','oocalc',
			     ],
	      'ods_viewer'=>['commande',
			     'libreoffice','localc','oocalc',
			     ],
	      'xml_viewer'=>['commande',
			     'gedit','kedit','kwrite','mousepad','leafpad',
			     ],
	      'tex_editor'=>['commande',
			     'texmaker','kile','gummi','emacs','gedit','kedit','kwrite','mousepad','leafpad',
			     ],
	      'txt_editor'=>['commande',
			     'gedit','kedit','kwrite','mousepad','emacs','leafpad',
			     ],
	      'html_browser'=>['commande',
			       'sensible-browser %u',
			       'firefox %u',
			       'galeon %u',
			       'konqueror %u',
			       'dillo %u',
			       'chromium %u',
			       ],
	      'dir_opener'=>['commande',
			     'nautilus --no-desktop file://%d',
			     'pcmanfm %d',
			     'Thunar %d',
			     'konqueror file://%d',
			     'dolphin %d',
			     ],
	      'print_command_pdf'=>['commande',
				    'cupsdoprint %f','lpr %f',
				    ],
	      'print_extract_with'=>'pdftk',
# TRANSLATORS: directory name for projects. This directory will be created (if needed) in the home directory of the user. Please use only alphanumeric characters, and - or _. No accentuated characters.
	      'rep_projets'=>$home_dir.'/'.__"MC-Projects",
	      'projects_home'=>$home_dir.'/'.__"MC-Projects",
	      'rep_modeles'=>$o_dir."/Models",
	      'seuil_eqm'=>3.0,
	      'seuil_sens'=>8.0,
	      'saisie_dpi'=>150,
	      'vector_scan_density'=>250,
	      'force_convert'=>'',
	      'n_procs'=>0,
	      'delimiteur_decimal'=>',',
	      'defaut_encodage_liste'=>'UTF-8',
	      'encodage_interne'=>'UTF-8',
	      'defaut_encodage_csv'=>'UTF-8',
	      'encodage_latex'=>'',
	      'defaut_moteur_latex_b'=>'pdflatex',
	      'defaut_seuil'=>0.15,
	      'defaut_seuil_up'=>1.0,
	      'assoc_window_size'=>'',
	      'mailing_window_size'=>'',
	      'preferences_window_size'=>'',
	      'checklayout_window_size'=>'',
	      'manual_window_size'=>'',
	      'conserve_taille'=>1,
	      'methode_impression'=>'CUPS',
	      'imprimante'=>'',
	      'printer_useful_options'=>'Staple Stapling StapleLocation StapleSet StapleOption',
	      'options_impression'=>{'sides'=>'two-sided-long-edge',
				     'number-up'=>1,
				     'repertoire'=>'/tmp',
				     'print_answersheet'=>'',
				     },
	      'manuel_image_type'=>'xpm',
	      'assoc_ncols'=>4,
	      'tolerance_marque_inf'=>0.2,
	      'tolerance_marque_sup'=>0.2,
	      'box_size_proportion'=>0.8,
	      'bw_threshold'=>0.6,
	      'ignore_red'=>0,
	      'try_three'=>1,

	      'prepare_solution'=>1,
	      'prepare_indiv_solution'=>1,
	      'prepare_catalog'=>1,

	      'symboles_trait'=>2,
	      'symboles_indicatives'=>'',
	      'symbole_0_0_type'=>'none',
	      'symbole_0_0_color'=>hex_color('black'),
	      'symbole_0_1_type'=>'circle',
	      'symbole_0_1_color'=>hex_color('red'),
	      'symbole_1_0_type'=>'mark',
	      'symbole_1_0_color'=>hex_color('red'),
	      'symbole_1_1_type'=>'mark',
	      'symbole_1_1_color'=>hex_color('blue'),

	      'annote_font_name'=>'Linux Libertine O 12',
	      'annote_ecart'=>5.5,
	      'annote_chsign'=>4,

	      'ascii_filenames'=>'',

	      'defaut_annote_rtl'=>'',
# TRANSLATORS: This is the default text to be written on the top of the first page of each paper when annotating. From this string, %s will be replaced with the student final mark, %m with the maximum mark he can obtain, %S with the student total score, and %M with the maximum score the student can obtain.
	      'defaut_verdict'=>"%(ID)\n".__("Mark: %s/%m (total score: %S/%M)"),
	      'defaut_verdict_q'=>"\"%"."s/%"."m\"",
	      'defaut_verdict_qc'=>"\"X\"",
	      'embedded_max_size'=>'1000x1500',
	      'embedded_format'=>'jpeg',
	      'embedded_jpeg_quality'=>75,

	      'zoom_window_height'=>400,
	      'zoom_window_factor'=>1.0,
	      'zooms_ncols'=>4,
	      'zooms_edit_mode'=>0,

	      'email_sender'=>'',
	      'email_cc'=>'',
	      'email_bcc'=>'',
	      'email_transport'=>'sendmail',
	      'email_sendmail_path'=>['commande',
				      '/usr/sbin/sendmail','/usr/bin/sendmail',
				      '/sbin/sendmail','/bin/sendmail'],
	      'email_smtp_host'=>'smtp',
	      'email_smtp_port'=>25,
# TRANSLATORS: Subject of the emails which can be sent to the students to give them their annotated completed answer sheet.
	      'defaut_email_subject'=>__"Exam result",
# TRANSLATORS: Body text of the emails which can be sent to the students to give them their annotated completed answer sheet.
	      'defaut_email_text'=>__"Please find enclosed your annotated completed answer sheet.\nRegards.",

	      'csv_surname_headers'=>'',
	      'csv_name_headers'=>'',
	      'notify_documents'=>0,
	      'notify_capture'=>1,
	      'notify_grading'=>1,
	      'notify_annotation'=>1,
	      'notify_desktop'=>1,
	      'notify_command'=>'',

              view_invalid_color=>"#FFEF3B",
              view_empty_color=>"#78FFED",
	      );

# MacOSX universal command to open files or directories : /usr/bin/open
if(lc($^O) eq 'darwin') {
    for my $k (qw/pdf_viewer img_viewer csv_viewer ods_viewer xml_viewer tex_editor txt_editor dir_opener/) {
	$o_defaut{$k}=['commande','/usr/bin/open','open'];
    }
    $o_defaut{'html_browser'}=['commande','/usr/bin/open %u','open %u'];
}


# Add default project options for each export module:

my @export_modules=perl_module_search('AMC::Export::register');
for my $m (@export_modules) {
  load("AMC::Export::register::$m");
  my %d="AMC::Export::register::$m"->options_default;
}
@export_modules=sort { "AMC::Export::register::$a"->weight
			 <=> "AMC::Export::register::$b"->weight }
  @export_modules;

# Reads filter plugins list

my @filter_modules=perl_module_search('AMC::Filter::register');
for my $m (@filter_modules) {
  load("AMC::Filter::register::$m");
}
@filter_modules=sort { "AMC::Filter::register::$a"->weight
             <=> "AMC::Filter::register::$b"->weight }
  @filter_modules;

sub best_filter_for_file {
  my ($file)=@_;
  my $mmax='';
  my $max=-10;
  for my $m (@filter_modules) {
    my $c="AMC::Filter::register::$m"->claim($file);
    if($c>$max) {
      $max=$c;
      $mmax=$m;
    }
  }
  return($mmax);
}

# -----------------

my %o=();


# Creates general options directory if not present

if(! -d $o_dir) {
    mkdir($o_dir) or die "Error creating $o_dir : $!";

    # gets older verions (<=0.254) main configuration file and move it
    # to the new location

    if(-f $home_dir.'/.AMC.xml') {
	move($home_dir.'/.AMC.xml',$o_dir."/cf.default.xml");
    }
}

for my $o_sub (qw/plugins/) {
  mkdir("$o_dir/$o_sub") if(! -d "$o_dir/$o_sub");
}

#

sub sub_modif {
  my ($opts)=@_;
  my ($m,$mo)=($opts->{'_modifie'},$opts->{'_modifie_ok'});
  for my $k (keys %$opts) {
    if(ref($opts->{$k}) eq 'HASH') {
      my ($m_sub,$mo_sub)=sub_modif($opts->{$k});
      $m=join_nonempty(',',$m,$m_sub);
      $mo=1 if($mo_sub);
    }
  }
  return($m,$mo);
}

sub clear_sub_modif {
  my ($data)=@_;
  delete($data->{_modifie});
  delete($data->{_modifie_ok});
  for my $k (grep { ref($data->{$_}) eq 'HASH' } (keys %$data)) {
    clear_sub_modif($data->{$k});
  }
}

# Read/write options XML files

sub pref_xx_lit {
  my ($fichier)=@_;
  if((! -f $fichier) || -z $fichier) {
    return();
  } else {
    my $data=XMLin($fichier,SuppressEmpty => '',
		   ForceArray=>['docs','email_attachment','printer']);
    clear_sub_modif($data);
    return(%$data);
  }
}

sub pref_xx_ecrit {
    my ($data,$key,$fichier,$data_orig)=@_;
    if(open my $fh,">:encoding(utf-8)",$fichier) {
	XMLout($data,
	       "XMLDecl"=>'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
	       "RootName"=>$key,'NoAttr'=>1,
	       "OutputFile" => $fh,
	       );
	close $fh;
	clear_sub_modif($data_orig || $data);
	return(0);
    } else {
	return(1);
    }
}




# Read the state file


$o_file=$o_dir."/cf.default.xml";

# Read general options ...

if(-r $o_file) {
    %o=pref_xx_lit($o_file);
}

sub set_option_to_default {
    my ($key,$subkey,$force)=@_;
    if($subkey) {
	if($force || ! exists($o{$key}->{$subkey})) {
	    $o{$key}->{$subkey}=$o_defaut{$key}->{$subkey};
	}
    } else {
	if($force || ! exists($o{$key})) {
	    # set to default
	    if(ref($o_defaut{$key}) eq 'ARRAY') {
		my ($type,@valeurs)=@{$o_defaut{$key}};
		if($type eq 'commande') {
		  UC: for my $c (@valeurs) {
		      if(commande_accessible($c)) {
			  $o{$key}=$c;
			  last UC;
		      }
		  }
		    if(!$o{$key}) {
			$o{$key}=$valeurs[0];
		    }
		} 
	    } elsif(ref($o_defaut{$key}) eq 'HASH') {
		$o{$key}={%{$o_defaut{$key}}};
	    } else {
		$o{$key}=$o_defaut{$key};
		$o{$key}=$encodage_systeme if($key =~ /^encodage_/ && !$o{$key});
	    }
	} else {
	    # already defined option: go with sub-options if any
	    if(ref($o_defaut{$key}) eq 'HASH') {
		for my $kk (keys %{$o_defaut{$key}}) {
		    set_option_to_default($key,$kk,$force);
		}
	    }
	}
    }
}

# sets undefined options to default value

for my $k (keys %o_defaut) {
    set_option_to_default($k);
}

# for unexisting commands options, see if we can find an available one
# from the default list


# Clears modified flag for the options

$o{'_modifie'}=0;
$o{'_modifie_ok'}=0;

# some options were renamed to defaut_* between 0.226 and 0.227

for(qw/encodage_liste encodage_csv/) {
    if($o{"$_"} && ! $o{"defaut_$_"}) {
	$o{"defaut_$_"}=$o{"$_"};
	$o{'_modifie'}=1;
    }
}

# Replace old (pre 0.280) rep_modeles value with new one

if($o{'rep_modeles'} eq '/usr/share/doc/auto-multiple-choice/exemples') {
    $o{'rep_modeles'}=$o_defaut{'rep_modeles'};
    $o{'_modifie'}=1;
}

# Internal encoding _must_ be UTF-8, for XML::Writer (used by
# AMC::Gui::Association for example) to work
if($o{'encodage_interne'} ne 'UTF-8') {
    $o{'encodage_interne'}='UTF-8';
    $o{'_modifie'}=1;
}


# goes to a specific directory if the project directory is given as a
# command-line option

if(-f $project_dir) {
  $project_dir =~ s/\/?options\.xml$//;
}
$project_dir =~ s/\/+$//;

if(-d $project_dir) {
  my ($v,$d,$f)=splitpath($project_dir);
  $o{'rep_projets'}=catpath($v,$d,'');
  $o{'rep_projets'} =~ s/\/+$//;
  @ARGV=$f;
}


# creates projets and models directories if needed (if not present,
# Edit/Parameters can be disrupted)

for my $k (qw/rep_projets rep_modeles/) {
  my $path=$o{$k};
  if(-e $path) {
  } else {
    mkdir($path);
  }
}


my $secret = $o{'api_secret'};
if ($generate_secret){
    $secret = join('', map(sprintf( q|%X| , rand(16)), 1..32));
    $o{'api_secret'} =$secret;
}
if ($show_secret){
    print("secret :",$secret);
} else {
    $api_url = $o{'api_url'} if (defined $o{'api_url'});
    $api_url = promptUser("Api url:",$api_url);
    $o{'api_url'} = $api_url;
    $o{'home_dir'} = $home_dir;
    if ($generate_secret){
        print("Secret :" , $secret);
    }

}
pref_xx_ecrit(\%o,'AMC',$o_file);

sub promptUser {

  my ($promptString,$defaultValue) = @_;

  
  if ($defaultValue) {
      print $promptString, "[", $defaultValue, "]: ";
  } else {
      print $promptString, ": ";
  }

  $| = 1;               # force a flush after our print
  $_ = <STDIN>;         # get the input from STDIN (presumably the keyboard)

  chomp;

  if ("$defaultValue") {
      return $_ ? $_ : $defaultValue;    # return $_ if it has a value
  } else {
      return $_;
  }
}



