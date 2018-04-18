#! /usr/bin/perl -w
#
# Copyright (C) 2008-2013 Alexis Bienvenue <paamc@passoire.fr>
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

use Plack::Request;
use Plack::Builder;
use JSON;

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
use Archive::Tar;
use Archive::Tar::File;
use Encode;
use Unicode::Normalize;
use I18N::Langinfo qw(langinfo CODESET);
use Locale::Language;
use Text::ParseWords;

use Module::Load;
use Module::Load::Conditional qw/check_install/;

use AMC::Path;
use AMC::Basic;
use AMC::State;
use AMC::Data;
use AMC::DataModule::capture ':zone';
use AMC::DataModule::report ':const';
use AMC::Scoring;
use CommandeApi;

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

# Sub

sub clear_sub_modif {
    my ($data)=@_;
    delete($data->{_modifie});
    delete($data->{_modifie_ok});
    for my $k (grep { ref($data->{$_}) eq 'HASH' } (keys %$data)) {
        clear_sub_modif($data->{$k});
    }
}

# Read/write options XML files
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
sub bon_encodage {
    my ($type)=@_;
    return($projet{'options'}->{"encodage_$type"}
	   || $o{"defaut_encodage_$type"}
	   || $o{"encodage_$type"}
	   || $o_defaut{"defaut_encodage_$type"}
	   || $o_defaut{"encodage_$type"}
	   || "UTF-8");
}

sub csv_build_0 {
  my ($k,@default)=@_;
  push @default,grep { $_ } map { s/^\s+//;s/\s+$//;$_; }
    split(/,+/,$o{'csv_'.$k.'_headers'});
  return("(".join("|",@default).")");
}

sub csv_build_name {
  return(csv_build_0('surname','nom','surname').' '
	 .csv_build_0('name','prenom','name'));
}

sub id2file {
    my ($id,$prefix,$extension)=(@_);
    $id =~ s/\+//g;
    $id =~ s/\//-/g;
    return($shortcuts->absolu($projet{'options'}->{'cr'})."/$prefix-$id.$extension");
}

sub is_local {
    my ($f,$proj)=@_;
    my $prefix=$o{'rep_projets'}."/";
    $prefix .= $projet{'nom'}."/" if($proj);
    if(defined($f)) {
	return($f !~ /^[\/%]/
	       || $f =~ /^$prefix/
	       || $f =~ /[\%]PROJET\//);
    } else {
	return('');
    }
}

sub fich_options {
    my ($nom,$rp)=@_;
    $rp=$o{'rep_projets'} if(!$rp);
    return "$rp/$nom/options.xml";
}

sub moteur_latex {
    my $m=$projet{'options'}->{'moteur_latex_b'};
    $m=$o{'defaut_moteur_latex_b'} if(!$m);
    $m=$o_defaut{'defaut_moteur_latex_b'} if(!$m);
    return($m);
}
sub get_enc {
    my ($txt)=@_;
    for my $e (@$encodages) {
	return($e) if($e->{'inputenc'} =~ /^$txt$/i ||
		      $e->{'iso'} =~ /^$txt$/i);
	if($e->{'alias'}) {
	    for my $a (@{$e->{'alias'}}) {
		return($e) if($a =~ /^$txt$/i);
	    }
	}
    }
    return('');
}

sub exporte {

  maj_export();

    my $format=$projet{'options'}->{'format_export'};
    my @options=();
    my $ext="AMC::Export::register::$format"->extension();
    if(!$ext) {
    $ext=lc($format);
    }
    my $type="AMC::Export::register::$format"->type();
    my $code=$projet{'options'}->{'code_examen'};
    $code=$projet{'nom'} if(!$code);
    my $output=$shortcuts->absolu('%PROJET/exports/'.$code.$ext);
    my @needs_module=();

    my %ofc="AMC::Export::register::$format"
      ->options_from_config($projet{'options'},\%o,\%o_defaut);
    for(keys %ofc) {
      push @options,"--option-out",$_.'='.$ofc{$_};
    }
    push @needs_module,"AMC::Export::register::$format"->needs_module();

    if(@needs_module) {
    # teste si les modules necessaires sont disponibles

    my @manque=();

    for my $m (@needs_module) {
        if(!check_install(module=>$m)) {
        push @manque,$m;
        }
    }

    if(@manque) {
        debug 'Exporting to '.$format.': Needs perl modules '.join(', ',@manque);#error
        return();
    }
    }

    commande('commande'=>["auto-multiple-choice","export",
              pack_args(
                    "--debug",debug_file(),
                    "--module",$format,
                    "--data",$shortcuts->absolu($projet{'options'}->{'data'}),
                    "--useall",$projet{'options'}->{'export_include_abs'},
                    "--sort",$projet{'options'}->{'export_sort'},
                    "--fich-noms",$shortcuts->absolu($projet{'options'}->{'listeetudiants'}),
                    "--noms-encodage",bon_encodage('liste'),
                    "--csv-build-name",csv_build_name(),
                    ($projet{'options'}->{'annote_rtl'} ? "--rtl" : "--no-rtl"),
                    "--output",$output,
                    @options
                   ),
             ],
         'texte'=>__"Exporting marks...",
         'progres.id'=>'export',
         'progres.pulse'=>0.01,
         'fin'=>sub {
           my ($c,%data)=@_;
           if(-f $output) {
         # shows export messages

         my $t=$c->higher_message_type();
         if($t) {
           $c->get_messages($t);#error

         }

         if($projet{'options'}->{'after_export'} eq 'file') {
           commande_parallele($o{$type.'_viewer'},$output)
             if($o{$type.'_viewer'});
         } elsif($projet{'options'}->{'after_export'} eq 'dir') {
           view_dir($shortcuts->absolu('%PROJET/exports/'));
         }
           } else {
         
            print( __"Export to %s did not work: file not created...",$output);#error

           }
         }
         );
}
sub commande {
    my (@opts)=@_;
    $cmd_id++;

    my $c=AMC::Gui::Commande::new('avancement'=>$w{'avancement'},
                  'log'=>$w{'log_general'},
                  'finw'=>sub {
                      my $c=shift;
                      $w{'onglets_projet'}->set_sensitive(1);
                      $w{'commande'}->hide();
                      delete $les_commandes{$c->{'_cmdid'}};
                  },
                  @opts);

    $c->{'_cmdid'}=$cmd_id;
    $les_commandes{$cmd_id}=$c;

    $w{'onglets_projet'}->set_sensitive(0);
    $w{'commande'}->show();

    $c->open();
}

sub commande_annule {
    for (keys %les_commandes) { $les_commandes{$_}->quitte(); }
}

sub commande_parallele {
    my (@c)=(@_);
    if(commande_accessible($c[0])) {
    my $pid=fork();
    if($pid==0) {
        debug "Command // [$$] : ".join(" ",@c);
        exec(@c) ||
        debug "Exec $$ : error";
        exit(0);
    }
    } else {
    
                  sprintf(__"Following command could not be run: <b>%s</b>, perhaps due to a poor configuration?",$c[0]));#error
    

    }
}
sub doc_maj {
    my $sur=0;
    if($projet{'_capture'}->n_pages_transaction()>0) {
    print(
                  __("Papers analysis was already made on the basis of the current working documents.")." "
                  .__("You already made the examination on the basis of these documents.")." "
                  .__("If you modify working documents, you will not be capable any more of analyzing the papers you have already distributed!")." "
                  .__("Do you wish to continue?")." "
                  .__("Click on OK to erase the former layouts and update working documents, or on Cancel to cancel this operation.")." "
                  ."<b>".__("To allow the use of an already printed question, cancel!")."</b>");#error
    
    if($reponse ne 'ok') {
        return(0);
    }

    $sur=1;
    }

    # deja des MEP fabriquees ?
    $projet{_layout}->begin_transaction('DMAJ');
    my $pc=$projet{_layout}->pages_count;
    $projet{_layout}->end_transaction('DMAJ');
    if($pc > 0) {
    if(!$sur) {
        print(
                  __("Layouts are already calculated for the current documents.")." "
                  .__("Updating working documents, the layouts will become obsolete and will thus be erased.")." "
                  .__("Do you wish to continue?")." "
                  .__("Click on OK to erase the former layouts and update working documents, or on Cancel to cancel this operation.")
                  ." <b>".__("To allow the use of an already printed question, cancel!")."</b>");#error
        

        if($reponse ne 'ok') {
        return(0);
        }
    }

    clear_processing('mep:');
    }

    # new layout document : XY (from LaTeX)

    if($projet{'options'}->{'doc_setting'} =~ /\.pdf$/) {
    $projet{'options'}->{'doc_setting'}=$projet_defaut{'doc_setting'};
    $projet{'options'}->{'_modifie'}=1;
    }

    # check for filter dependencies

    my $filter_register=("AMC::Filter::register::".$projet{'options'}->{'filter'})
      ->new();

    my $check=$filter_register->check_dependencies();

    if(!$check->{'ok'}) {
      my $message=sprintf(__("To handle properly <i>%s</i> files, AMC needs the following components, that are currently missing:"),$filter_register->name())."\n";
      for my $k (qw/latex_packages commands fonts/) {
    if(@{$check->{$k}}) {
      $message .= "<b>".$component_name{$k}."</b> ";
      if($k eq 'fonts') {
        $message.=join(', ',map { @{$_->{'family'}} } @{$check->{$k}});
      } else {
        $message.=join(', ',@{$check->{$k}});
      }
      $message.="\n";
    }
      }
      $message.=__("Install these components on your system and try again.");

      print($message);#error
      

      return(0);
    }

    # set options from filter:

    if($projet{'options'}->{'filter'}) {
      $filter_register->set_oo($projet{'options'});
      $filter_register->configure();
    }

    # remove pre-existing DOC-corrected.pdf (built by AMC-annotate)
    my $pdf_corrected=$shortcuts->absolu("DOC-corrected.pdf");
    if(-f $pdf_corrected) {
      debug "Removing pre-existing $pdf_corrected";#error
      unlink($pdf_corrected);
    }

    #
    my $mode_s='s[';
    $mode_s.='s' if($o{'prepare_solution'});
    $mode_s.='c' if($o{'prepare_catalog'});
    $mode_s.=']';
    $mode_s.='k' if($o{'prepare_indiv_solution'});
    commande('commande'=>["auto-multiple-choice","prepare",
              "--with",moteur_latex(),
              "--filter",$projet{'options'}->{'filter'},
              "--filtered-source",$shortcuts->absolu($projet{'options'}->{'filtered_source'}),
              "--debug",debug_file(),
              "--out-sujet",$shortcuts->absolu($projet{'options'}->{'doc_question'}),
              "--out-corrige",$shortcuts->absolu($projet{'options'}->{'doc_solution'}),
              "--out-corrige-indiv",$shortcuts->absolu($projet{'options'}->{'doc_indiv_solution'}),
              "--out-catalog",$shortcuts->absolu($projet{'options'}->{'doc_catalog'}),
              "--out-calage",$shortcuts->absolu($projet{'options'}->{'doc_setting'}),
              "--mode",$mode_s,
              "--n-copies",$projet{'options'}->{'nombre_copies'},
              $shortcuts->absolu($projet{'options'}->{'texsrc'}),
              "--prefix",$shortcuts->absolu('%PROJET/'),
              "--latex-stdout",
              ],
         'signal'=>2,
         'texte'=>__"Documents update...",
         'progres.id'=>'MAJ',
         'progres.pulse'=>0.01,
         'fin'=>sub {
         my ($c,%data)=@_;
         if(!$data{cancelled}) {
           my @err=$c->erreurs();
           my @warn=$c->warnings();
           if (@err || @warn) {
             

             my $message=__("Problems while processing the source file.")
               ." "
             .__("You have to correct the source file and re-run documents update.");

             if(@err) {
               $message.="\n\n".__("<b>Errors</b>")."\n"
             .join("\n",map { format_markup($_) } (@err[0..mini(9,$#err)])).($#err>9 ? "\n\n<i>(".__("Only first ten errors written").")</i>": "");

             }
             if(@warn) {
               $message.="\n\n".__("<b>Warnings</b>")."\n"
             .join("\n",map { format_markup($_) } (@warn[0..mini(9,$#warn)])).($#warn>9 ? "\n\n<i>(".__("Only first ten warnings written").")</i>": "");

             }

             $message.="\n\n".
               # TRANSLATORS: Here, %s will be replaced with the translation of "Command output details", and refers to the small expandable part at the bottom of AMC main window, where one can see the output of the commands lauched by AMC.
               sprintf(__("See also the processing log in '%s' below."),
                   # TRANSLATORS: Title of the small expandable part at the bottom of AMC main window, where one can see the output of the commands lauched by AMC.
                   __"Command output details");
             $message.=" ".__("Use LaTeX editor or latex command for a precise diagnosis.") if($projet{'options'}->{'filter'} eq 'latex');

             print($message);#error
             
           } else {
             print('documents',
                    __"Documents have been prepared");

             # verif que tout y est

             my $ok=1;
             for (qw/question solution setting/) {
               $ok=0 if(! -f $shortcuts->absolu($projet{'options'}->{'doc_'.$_}));
             }
             if ($ok) {

               # set project option from filter requests

               my %vars=$c->variables;
               for my $k (keys %vars) {
             if ($k =~ /^project:(.*)/) {
               set_project_option($1,$vars{$k});
             }
               }

             }
           }

           # Try to guess the best place to write question
           # scores when annotating. This option can be
           # changed later in the Edit/Preferences window.
           my $ap='marges';
           if($c->variable('scorezones')) {
             $ap='zones';
           } elsif($c->variable('ensemble')) {
             $ap='cases';
           }
           $projet{'options'}->{'_modifie'}=1
             if ($projet{'options'}->{'annote_position'} ne $ap);
           $projet{'options'}->{'annote_position'}=$ap;

           my $ensemble=$c->variable('ensemble') && !$c->variable('outsidebox');
           if (($ensemble  || $c->variable('insidebox'))
               && $projet{'options'}->{'seuil'}<0.4) {
             
                     sprintf(($ensemble ?
                          __("Your question has a separate answers sheet.")." "
                          .__("In this case, letters are shown inside boxes.") :
                          __("Your question is set to present labels inside the boxes to be ticked."))
                         ." "
                         # TRANSLATORS: Here, %s will be replaced with the translation of "darkness threshold".
                         .__("For better ticking detection, ask students to fill out completely boxes, and choose parameter \"%s\" around 0.5 for this project.")." "
                         .__("At the moment, this parameter is set to %.02f.")." "
                         .__("Would you like to set it to 0.5?")
                         # TRANSLATORS: This parameter is the ratio of dark pixels number over total pixels number inside box above which a box is considered to be ticked.
                         ,__"darkness threshold",
                         $projet{'options'}->{'seuil'}) );#error
             
             if ($reponse eq 'yes') {
               $projet{'options'}->{'seuil'}=0.5;
               $projet{'options'}->{'seuil_up'}=1.0;
               $projet{'options'}->{'_modifie'}=1;
             }
           }
         }
         detecte_documents();
         });

}
sub sujet_impressions_ok {
    my $os='none';
    my @e=();

    for my $i ($w{'arbre_choix_copies'}->get_selection()->get_selected_rows() ) {
    push @e,$copies_store->get($copies_store->get_iter($i),COPIE_N);
    }

    $prefs->reprend_pref('impall',$o{'options_impression'});

    if($o{'methode_impression'} =~ /^CUPS/) {
    my $i=$w{'imprimante'}->get_model->get($w{'imprimante'}->get_active_iter,COMBO_ID);
    if($i ne $o{'imprimante'}) {
        $o{'imprimante'}=$i;
        $o{'_modifie'}=1;
    }

    $prefs->reprend_pref('imp',$o{'options_impression'});
    $prefs->reprend_pref('printer',$o{options_impression}->{printer}->{$i});

    $os=options_string($o{options_impression},
               $o{options_impression}->{printer}->{$i});

    debug("Printing options : $os");
    }

    if($o{'methode_impression'} eq 'file') {
    $prefs->reprend_pref('impf',$o{'options_impression'});

    if($o{'options_impression'}->{'_modifie'}) {
        $o{'_modifie'}=1;
        delete $o{'options_impression'}->{'_modifie'};
    }

    if(!$o{'options_impression'}->{'repertoire'}) {
        debug "Print to file : no destionation...";#error
        $o{'options_impression'}->{'repertoire'}='';
    } else {
      my $path=$shortcuts->absolu($o{'options_impression'}->{'repertoire'});
      mkdir($path) if(! -e $path);
    }
    }

    $w{'choix_pages_impression'}->destroy;

    debug "Printing: ".join(",",@e);#error

    if(!@e) {
    # No page selected:
    print(
          __("You did not select any exam to print..."));#error
    return();
    }

    if(1+$#e <= 10) {
      # Less than 10 pages selected: is it a mistake?

      $projet{'_layout'}->begin_read_transaction('pPFP');
      my $max_p=$projet{'_layout'}->max_enter();
      my $students=$projet{'_layout'}->students_count();
      $projet{'_layout'}->end_transaction('pPFP');

      if($max_p>1) {
    # Some sheets have more than one enter-page: multiple scans
    # are not supported...

    return() if($resp eq 'no');
      } elsif($students<=10) {
    if($projet{'options'}->{'auto_capture_mode'} != 1) {
      # This looks strange: a few sheets printed, a few sheets
      # generated, and photocopy mode not selected yet. Ask the
      # user if he wants to select this mode now.
      print(
                  __("You selected only a few sheets to print.")."\n".
                  "<b>".__("Are you going to photocopy some printed subjects before giving them to the students?")."</b>\n".
                  __("If so, the corresponding option will be set for this project.")." ".
                  __("However, you will be able to change this when giving your first scans to AMC.")
                 );#error
      
      my $mult=($reponse eq 'yes' ? 1 : 0);
      if($mult != $projet{'options'}->{'auto_capture_mode'}) {
        $projet{'options'}->{'auto_capture_mode'}=$mult;
        $projet{'options'}->{'_modifie_ok'}=1;
      }
    }
      }
    }

    if($o{'options_impression'}->{'print_answersheet'} eq 'first') {
      # This options needs pdftk!
      if($o{print_extract_with} ne 'pdftk') {
    if(commande_accessible('pdftk')) {
      print(
# TRANSLATORS: the two %s will be replaced by the translations of "Answer sheet first" and "Extracting method".
                  sprintf(__("You selected the '%s' option, that uses 'pdftk', so the %s has been set to 'pdftk' for you."),
                      __("Answer sheet first"),__("Extracting method"))
                 );#error
      

      $o{print_extract_with}='pdftk';
      $o{_modifie}.=',print_extract_with';$o{_modifie_ok}=1;
    } else {
      
                  sprintf(__("You selected the '%s' option, but this option needs 'pdftk' to be installed on your system. Please install it and try again."),
                      __"Answer sheet first")
                 );
      
      return();
    }
      }
    }

    my $fh=File::Temp->new(TEMPLATE => "nums-XXXXXX",
               TMPDIR => 1,
               UNLINK=> 1);
    print $fh join("\n",@e)."\n";
    $fh->seek( 0, SEEK_END );

    my @o_answer=('--no-split','--no-answer-first');
    if($o{'options_impression'}->{'print_answersheet'} eq 'split') {
      @o_answer=('--split','--no-answer-first');
    } elsif($o{'options_impression'}->{'print_answersheet'} eq 'first') {
      @o_answer=('--answer-first','--no-split');
    }

    commande('commande'=>["auto-multiple-choice","imprime",
              "--methode",$o{'methode_impression'},
              "--imprimante",$o{'imprimante'},
              "--options",$os,
              "--output",$shortcuts->absolu($o{'options_impression'}->{'repertoire'})."/sheet-%e.pdf",
              @o_answer,
              "--print-command",$o{'print_command_pdf'},
              "--sujet",$shortcuts->absolu($projet{'options'}->{'doc_question'}),
              "--data",$shortcuts->absolu($projet{'options'}->{'data'}),
              "--progression-id",'impression',
              "--progression",1,
              "--debug",debug_file(),
              "--fich-numeros",$fh->filename,
              "--extract-with",$o{'print_extract_with'},
              ],
         'signal'=>2,
         'texte'=>__"Print papers one by one...",
         'progres.id'=>'impression',
         'o'=>{'fh'=>$fh,'etu'=>\@e,'printer'=>$o{'imprimante'},'method'=>$o{'methode_impression'}},
         'fin'=>sub {
         my $c=shift;
         close($c->{'o'}->{'fh'});
         save_state_after_printing($c->{'o'});
         },

         );
}
sub save_state_after_printing {
    my $c=shift;
    my $st=AMC::State::new('directory'=>$shortcuts->absolu('%PROJET/'));

    $st->read();

    my @files=grep { -f $shortcuts->absolu($_) }
      map { $projet{'options'}->{'doc_'.$_} }
      (qw/question solution setting catalog/);
    push @files,$shortcuts->absolu($projet{'options'}->{'texsrc'});

    push @files,$shortcuts->absolu($projet{'options'}->{'filtered_source'})
      if(-f $shortcuts->absolu($projet{'options'}->{'filtered_source'}));

    if(!$st->check_local_md5(@files)) {
    $st=AMC::State::new('directory'=>$shortcuts->absolu('%PROJET/'));
    $st->add_local_files(@files);
    }

    $st->add_print('printer'=>$c->{'printer'},
           'method'=>$c->{'method'},
           'content'=>join(',',@{$c->{'etu'}}));
    $st->write();

}

sub calcule_mep {
    if($projet{'options'}->{'doc_setting'} !~ /\.xy$/) {
    # OLD STYLE WORKING DOCUMENTS... Not supported anymore: update!
    print(
                  __("Working documents are in an old format, which is not supported anymore.")." <b>"
                  .__("Please generate again the working documents!")."</b>");
    

    return;
    }

    commande('commande'=>["auto-multiple-choice","meptex",
              "--debug",debug_file(),
              "--src",$shortcuts->absolu($projet{'options'}->{'doc_setting'}),
              "--progression-id",'MEP',
              "--progression",1,
              "--data",$shortcuts->absolu($projet{'options'}->{'data'}),
              ],
         'texte'=>__"Detecting layouts...",
         'progres.id'=>'MEP',
         'fin'=>sub {
           my ($c,%data)=@_;
           detecte_mep();
           if(!$data{cancelled}) {
         $projet{'_layout'}->begin_read_transaction('PGCN');
         my $c=$projet{'_layout'}->pages_count();
         $projet{'_layout'}->end_transaction('PGCN');
         if($c<1) {
           # avertissement...
           print(
                       __("No layout detected.")." "
                       .__("<b>Don't go through the examination</b> before fixing this problem, otherwise you won't be able to use AMC for correction."));#error
           

         } else {
           
         }
           }
         });
}
sub analyse_call {
  my (%oo)=@_;
  # make temporary file with the list of images to analyse

  my $fh=File::Temp->new(TEMPLATE => "liste-XXXXXX",
             TMPDIR => 1,
             UNLINK=> 1);
  print $fh join("\n",@{$oo{'f'}})."\n";
  $fh->seek( 0, SEEK_END );

  if($oo{'getimages'}) {
    my @args=("--progression-id",'analyse',
          "--list",$fh->filename,
          "--debug",debug_file(),
          "--vector-density",$o{'vector_scan_density'},
         );
    push @args,"--copy-to",$oo{'copy'} if($oo{'copy'});
    push @args,"--force-convert" if($o{force_convert});
    $projet{_layout}->begin_transaction('Orie');
    my $orientation=$projet{_layout}->orientation();
    $projet{_layout}->end_transaction('Orie');
    push @args,"--orientation",$orientation if($orientation);

    debug "Target orientation: $orientation";

    commande('commande'=>["auto-multiple-choice","getimages",
              @args],
         'signal'=>2,
         'progres.id'=>$oo{'progres'},
         'fin'=>sub {
           my ($c,%data)=@_;
           if(!$data{cancelled}) {
         analyse_call_go('liste'=>$fh->filename,'fh'=>$fh,%oo);
           }
         },
        );
  } else {
    analyse_call_go('liste'=>$fh->filename,'fh'=>$fh,%oo);
  }
}

sub analyse_call_go {
  my (%oo)=@_;
  my @args=("--debug",debug_file(),
        ($projet{'options'}->{'auto_capture_mode'} ? "--multiple" : "--no-multiple"),
        "--tol-marque",$o{'tolerance_marque_inf'}.','.$o{'tolerance_marque_sup'},
        "--prop",$o{'box_size_proportion'},
        "--bw-threshold",$o{'bw_threshold'},
        "--progression-id",'analyse',
        "--progression",1,
        "--n-procs",$o{'n_procs'},
        "--data",$shortcuts->absolu($projet{'options'}->{'data'}),
        "--projet",$shortcuts->absolu('%PROJET/'),
        "--cr",$shortcuts->absolu($projet{'options'}->{'cr'}),
        "--liste-fichiers",$oo{'liste'},
        ($o{'ignore_red'} ? "--ignore-red" : "--no-ignore-red"),
        ($o{'try_three'} ? "--try-three" : "--no-try-three"),
       );

  push @args,"--pre-allocate",$oo{'allocate'} if($oo{'allocate'});

  # Diagnostic image file ?

  if($oo{'diagnostic'}) {
    push @args,"--debug-image-dir",$shortcuts->absolu('%PROJET/cr/diagnostic');
  }

  # call AMC-analyse

  commande('commande'=>["auto-multiple-choice","analyse",
            @args],
       'signal'=>2,
       'texte'=>$oo{'text'},
       'progres.id'=>$oo{'progres'},
       'o'=>{'fh'=>$oo{'fh'}},
       'fin'=>$oo{'fin'},
      );
}
# automatic association
sub associe_auto {
    return() if(!check_possible_assoc(1));

    commande('commande'=>["auto-multiple-choice","association-auto",
              pack_args("--data",$shortcuts->absolu($projet{'options'}->{'data'}),
                    "--notes-id",$projet{'options'}->{'assoc_code'},
                    "--liste",$shortcuts->absolu($projet{'options'}->{'listeetudiants'}),
                    "--liste-key",$projet{'options'}->{'liste_key'},
                    "--csv-build-name",csv_build_name(),
                    "--encodage-liste",bon_encodage('liste'),
                    "--debug",debug_file(),
                    ($projet{'options'}->{'assoc_code'} eq '<preassoc>' ?
                     "--pre-association" : "--no-pre-association"),
                   ),
         ],
         'texte'=>__"Automatic association...",
         'fin'=>sub {
           my ($c,%data)=@_;
           assoc_state();
           assoc_resultat() if(!$data{cancelled});
         },
    );
}
sub noter {
  if($projet{'options'}->{'maj_bareme'}) {
    my $mode="b";
    my $pdf_corrected=$shortcuts->absolu($projet{'options'}->{'doc_indiv_solution'});
    if(-f $pdf_corrected) {
      debug "Removing pre-existing $pdf_corrected";
      unlink($pdf_corrected);
    }
    $mode.='k' if($o{'prepare_indiv_solution'});

    my $n_copies=$projet{'options'}->{'nombre_copies'};
    commande('commande'=>["auto-multiple-choice","prepare",
              "--out-corrige-indiv",$pdf_corrected,
              "--n-copies",$n_copies,
              "--with",moteur_latex(),
              "--filter",$projet{'options'}->{'filter'},
              "--filtered-source",$shortcuts->absolu($projet{'options'}->{'filtered_source'}),
              "--debug",debug_file(),
              "--progression-id",'bareme',
              "--progression",1,
              "--data",$shortcuts->absolu($projet{'options'}->{'data'}),
              "--mode",$mode,
              $shortcuts->absolu($projet{'options'}->{'texsrc'}),
             ],
         'texte'=>__"Extracting marking scale...",
         'fin'=>\&noter_postcorrect,
         'progres.id'=>'bareme');
  } else {
    noter_calcul('','');
  }
}
sub noter_calcul {

    my ($postcorrect_student,$postcorrect_copy,$postcorrect_set_multiple)=@_;

    debug "Using sheet $postcorrect_student:$postcorrect_copy to get correct answers"     if($postcorrect_student);

    # computes marks.

    commande('commande'=>["auto-multiple-choice","note",
              "--debug",debug_file(),
              "--data",$shortcuts->absolu($projet{'options'}->{'data'}),
              "--seuil",$projet{'options'}->{'seuil'},
              "--seuil-up",$projet{'options'}->{'seuil_up'},

              "--grain",$projet{'options'}->{'note_grain'},
              "--arrondi",$projet{'options'}->{'note_arrondi'},
              "--notemax",$projet{'options'}->{'note_max'},
              ($projet{'options'}->{'note_max_plafond'} ? "--plafond" : "--no-plafond"),
              "--notenull",$projet{'options'}->{'note_null'},
              "--notemin",$projet{'options'}->{'note_min'},
              "--postcorrect-student",$postcorrect_student,
              "--postcorrect-copy",$postcorrect_copy,
              ($postcorrect_set_multiple ?
               "--postcorrect-set-multiple" :
               "--no-postcorrect-set-multiple"),

              "--progression-id",'notation',
              "--progression",1,
              ],
         'signal'=>2,
         'texte'=>__"Computing marks...",
         'progres.id'=>'notation',
         'fin'=>sub {
           my ($c,%data)=@_;
           notify_end_of_work('grading',
                  __"Grading has been completed")
         if(!$data{cancelled});
           noter_resultat();
         },
         );
}
sub opt_symbole {
    my ($s)=@_;
    my $k=$s;
    my $type='none';
    my $color='red';

    $k =~ s/-/_/g;
    $type=$o{'symbole_'.$k.'_type'} if(defined($o{'symbole_'.$k.'_type'}));
    $color=$o{'symbole_'.$k.'_color'} if(defined($o{'symbole_'.$k.'_color'}));

    return("$s:$type/$color");
}
sub annote_copies {
  my $id_file='';

  if($projet{'options'}->{'regroupement_copies'} eq 'SELECTED') {
    # use a file in project directory to store students ids for which
    # sheets will be annotated
    $id_file=$shortcuts->absolu('%PROJET/selected-ids');
    return() if(!select_students($id_file));
  }

  my $single_output='';

  if($projet{'options'}->{'regroupement_type'} eq 'ALL') {
    $single_output=($id_file ?
# TRANSLATORS: File name for single annotated answer sheets with only some selected students. Please use simple characters.
                   (__("Selected_students")).".pdf" :
# TRANSLATORS: File name for single annotated answer sheets with all students. Please use simple characters.
                   (__("All_students")).".pdf" );
  }

  commande('commande'=>["auto-multiple-choice","annotate",
            pack_args("--cr",$shortcuts->absolu($projet{'options'}->{'cr'}),
                  "--project",$shortcuts->absolu('%PROJET/'),
                  "--projects",$shortcuts->absolu('%PROJETS/'),
                  "--data",$shortcuts->absolu($projet{'options'}->{'data'}),
                  "--subject",$shortcuts->absolu($projet{'options'}->{'doc_question'}),
                  "--corrected",$shortcuts->absolu($projet{'options'}->{'doc_indiv_solution'}),
                  "--filename-model",$projet{'options'}->{'modele_regroupement'},
                  ($o{'ascii_filenames'}?"--force-ascii":"--no-force-ascii"),
                  "--single-output",$single_output,
                  "--sort",$projet{'options'}->{'export_sort'},
                  "--id-file",$id_file,
                  "--debug",debug_file(),
                  "--progression-id",'annotate',
                  "--progression",1,
                  "--line-width",$o{'symboles_trait'},
                  "--font-name",$o{'annote_font_name'},
                  "--symbols",join(',',map { opt_symbole($_); } 
                           (qw/0-0 0-1 1-0 1-1/)),
                  ($o{'symboles_indicatives'}?"--indicatives":"--no-indicatives"),
                  "--position",$projet{'options'}->{'annote_position'},
                  "--dist-to-box",$o{'annote_ecart'},
                  "--n-digits",$o{'annote_chsign'},
                  "--verdict",$projet{'options'}->{'verdict'},
                  "--verdict-question",$projet{'options'}->{'verdict_q'},
                  "--verdict-question-cancelled",$projet{'options'}->{'verdict_qc'},
                  "--names-file",$shortcuts->absolu($projet{'options'}->{'listeetudiants'}),
                  "--names-encoding",bon_encodage('liste'),
                  "--csv-build-name",csv_build_name(),
                  ($projet{'options'}->{'annote_rtl'} ? "--rtl" : "--no-rtl"),
                  "--changes-only",1,
                  "--sort",$projet{'options'}->{'export_sort'},
                  "--compose",$projet{'options'}->{'regroupement_compose'},
                  "--n-copies",$projet{'options'}->{'nombre_copies'},
                  "--src",$shortcuts->absolu($projet{'options'}->{'texsrc'}),
                  "--with",moteur_latex(),
                  "--filter",$projet{'options'}->{'filter'},
                  "--filtered-source",$shortcuts->absolu($projet{'options'}->{'filtered_source'}),
                  "--embedded-max-size",$o{'embedded_max_size'},
                  "--embedded-format",$o{'embedded_format'},
                  "--embedded-jpeg-quality",$o{'embedded_jpeg_quality'},
                 )
               ],
       'texte'=>__"Annotating papers...",
       'progres.id'=>'annotate',
       'fin'=>sub {
         my ($c,%data);
         notify_end_of_work('annotation',__"Annotations have been completed")
           if(!$data{cancelled});
       },
      );
}

sub annotate_papers {

  valide_options_notation();
  maj_export();

  annote_copies;
}
sub clear_processing {
  my ($steps)=@_;
  my $next='';
  my %s=();
  for my $k (qw/doc mep capture mark assoc/) {
    if($steps =~ /\b$k:/) {
      $next=1;
      $s{$k}=1;
    } elsif($next || $steps =~ /\b$k\b/) {
      $s{$k}=1;
    }
  }

  if($s{'doc'}) {
    for (qw/question solution setting catalog/) {
      my $f=$shortcuts->absolu($projet{'options'}->{'doc_'.$_});
      unlink($f) if(-f $f);
    }
    detecte_documents();
  }

  delete($s{'doc'});
  return() if(!%s);

  # data to remove...

  $projet{'_data'}->begin_transaction('CLPR');

  if($s{'mep'}) {
    $projet{_layout}->clear_all;
  }

  if($s{'capture'}) {
    $projet{_capture}->clear_all;
  }

  if($s{'mark'}) {
    $projet{'_scoring'}->clear_strategy;
    $projet{'_scoring'}->clear_score;
  }

  if($s{'assoc'}) {
    $projet{_association}->clear;
  }

  $projet{'_data'}->end_transaction('CLPR');

  # files to remove...

  if($s{'capture'}) {
    # remove zooms
    remove_tree($shortcuts->absolu('%PROJET/cr/zooms'),
        {'verbose'=>0,'safe'=>1,'keep_root'=>1});
    # remove namefield extractions and page layout image
    my $crdir=$shortcuts->absolu('%PROJET/cr');
    opendir(my $dh,$crdir);
    my @cap_files=grep { /^(name-|page-)/ } readdir($dh);
    closedir($dh);
    for(@cap_files) {
      unlink "$crdir/$_";
    }
  }

  # update gui...

  if($s{'mep'}) {
    detecte_mep();
  }
  if($s{'capture'}) {
    detecte_analyse();
  }
  if($s{'mark'}) {
    noter_resultat();
  }
  if($s{'assoc'}) {
    assoc_state();
  }
}

my $home_dir = cwd;
my $o_file='';
my $o_dir = $home_dir;
my $state_file="$o_dir/state.xml";
my %o=();
my %state=();
# Read the state file

if(-r $state_file) {
    %state=pref_xx_lit($state_file);
    $state{'apprentissage'}={} if(!$state{'apprentissage'});
}

$state{'_modifie'}=0;
$state{'_modifie_ok'}=0;

# gets the last used profile

if(!$state{'profile'}) {
    $state{'profile'}='default';
    $state{'_modifie'}=1;
}



$o_file=$o_dir."/cf.".$state{'profile'}.".xml";

# Read general options ...

if(-r $o_file) {
    %o=pref_xx_lit($o_file);
}

my $base_url = $o{'api_url'}; 

my $app = sub {
    my $request = Plack::Request->new(shift);
    my $json;
    my $post = $request->body_parameters->as_hashref;
    my $data = $post;
    my @errors = ();
    $data->{ip} = $request->address;
    $data->{remote_host} = $request->remote_host;
    $data->{referer} = $request->referer;
    $json = {status => 200,
             message => 'success',
             errors => \@errors,
             data => $data
     };

    my $response  = $request->new_response(200);
    $response->content_type('application/json');
    $response->content(encode_json($json));

    return $response->finalize;
};

builder {
    mount $base_url."/quiz" => $app;
    mount $base_url."/document" => $app;
    mount $base_url."/sheet" => $app;
    mount $base_url."/association" => $app;
    mount $base_url."/grading" => $app;
    mount $base_url."/annotation" => $app;
    mount $base_url."/file" => $app;
    mount $base_url."/" => $app;
}


