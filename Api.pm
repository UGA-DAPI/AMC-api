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

package Api;

BEGIN {
    our $VERSION = 1.0;
}

use XML::Simple;
use IO::File;
use IO::Select;
use POSIX qw/strftime/;
use Time::Local;
use Cwd;
use File::Spec::Functions
    qw/splitpath catpath splitdir catdir catfile rel2abs tmpdir/;
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

use Config;
use CommandeApi;
use JSON;
use MIME::Base64 qw(decode_base64);

use utf8;

use constant {
    DOC_TITRE => 0,
    DOC_MAJ   => 1,

    MEP_PAGE => 0,
    MEP_ID   => 1,
    MEP_MAJ  => 2,

    DIAG_ID         => 0,
    DIAG_ID_BACK    => 1,
    DIAG_MAJ        => 2,
    DIAG_EQM        => 3,
    DIAG_EQM_BACK   => 4,
    DIAG_DELTA      => 5,
    DIAG_DELTA_BACK => 6,
    DIAG_ID_STUDENT => 7,
    DIAG_ID_PAGE    => 8,
    DIAG_ID_COPY    => 9,

    INCONNU_FILE    => 0,
    INCONNU_SCAN    => 1,
    INCONNU_TIME    => 2,
    INCONNU_TIME_N  => 3,
    INCONNU_PREPROC => 4,

    PROJ_NOM => 0,
    PROJ_ICO => 1,

    MODEL_NOM  => 0,
    MODEL_PATH => 1,
    MODEL_DESC => 2,

    COPIE_N => 0,

    TEMPLATE_FILES_PATH => 0,
    TEMPLATE_FILES_FILE => 1,

    EMAILS_SC     => 0,
    EMAILS_NAME   => 1,
    EMAILS_EMAIL  => 2,
    EMAILS_ID     => 3,
    EMAILS_STATUS => 4,

    ATTACHMENTS_FILE       => 0,
    ATTACHMENTS_NAME       => 1,
    ATTACHMENTS_FOREGROUND => 2,
};

my $debug      = 0;
my $debug_file = '';
if ($debug_file) {
    $debug = $debug_file;
}

if ($debug) {
    set_debug_mode($debug);
}

sub bon_encodage {
    my ( $self, $type ) = @_;
    return (   $self->{config}->get("encodage_$type")
            || $self->{config}->get("defaut_encodage_$type")
            || "UTF-8" );
}

sub csv_build_0 {
    my ( $self, $k, @default ) = @_;
    push @default, grep {$_} map { s/^\s+//; s/\s+$//; $_; }
        split( /,+/, $self->{config}->get( 'csv_' . $k . '_headers' ) );
    return ( "(" . join( "|", @default ) . ")" );
}

sub csv_build_name {
    my $self = shift;
    return (  csv_build_0( 'surname', 'nom', 'surname' ) . ' '
            . csv_build_0( 'name', 'prenom', 'name' ) );
}

sub moteur_latex {
    my $self = shift;
    return (   $self->{config}->get('moteur_latex_b')
            || $self->{config}->get('defaut_moteur_latex_b') );
}

sub exporte {

    my $self    = shift;
    my $format  = $self->{config}->get('format_export');
    my @options = ();
    my $ext     = "AMC::Export::register::$format"->extension();
    if ( !$ext ) {
        $ext = lc($format);
    }
    my $type = "AMC::Export::register::$format"->type();
    my $code = $self->{config}->get('code_examen');
    $code = $self->{project}->{'nom'} if ( !$code );
    utf8::encode($code);
    my $output
        = $self->{config}->get_absolute( '%PROJET/exports/' . $code . $ext );
    my @needs_module = ();

    my %ofc = "AMC::Export::register::$format"
        ->options_from_config( $self->{config} );
    for ( keys %ofc ) {
        push @options, "--option-out", $_ . '=' . $ofc{$_};
    }
    push @needs_module, "AMC::Export::register::$format"->needs_module();

    if (@needs_module) {

        # teste si les modules necessaires sont disponibles
        my @manque = ();
        for my $m (@needs_module) {
            if ( !check_install( module => $m ) ) {
                push @manque, $m;
            }
        }
        if (@manque) {
            print(
                __( "Exporting to '%s' needs some perl modules that are not installed: %s. Please install these modules or switch to another export format."
                ),
                "AMC::Export::register::$format"->name(),
                join( ', ', @manque )
            );
            return ();
        }
    }
    commande(
        'commande' => [
            "auto-multiple-choice",
            "export",
            pack_args(
                "--debug",
                debug_file(),
                "--module",
                $format,
                "--data",
                $self->{config}->get_absolute('data'),
                "--useall",
                $self->{config}->get('export_include_abs'),
                "--sort",
                $self->{config}->get('export_sort'),
                "--fich-noms",
                $self->{config}->get_absolute('listeetudiants'),
                "--noms-encodage",
                $self->bon_encodage('liste'),
                "--csv-build-name",
                $self->csv_build_name(),
                ( $self->{config}->get('annote_rtl') ? "--rtl" : "--no-rtl" ),
                "--output",
                $output,
                @options
            ),
        ],
        'texte'         => __ "Exporting marks...",
        'progres.id'    => 'export',
        'progres.pulse' => 0.01,
        'fin'           => sub {
            my ( $c, %data ) = @_;
            if ( -f $output ) {

                # shows export messages

                $c->erreurs();    #error
                $c->warning();    #error

            }
            else {
                print( __"Export to %s did not work: file not created...",
                    $output );    #error
            }
        }
    );
}

sub commande {
    my (@opts) = @_;

    my $c = CommandeApi::new(
        'finw' => sub {
            my $c = shift;

            #delete $les_commandes{$c->{'_cmdid'}};
        },
        @opts
    );
    $c->execute();
}

sub doc_maj {
    my ( $self, sur ) = @_;
    if ( $self->{project}->{'_capture'}->n_pages_transaction() > 0 ) {
        push(
            $self->{messages},
            __( "Papers analysis was already made on the basis of the current working documents."
                )
                . " "
                . __(
                "You already made the examination on the basis of these documents."
                )
                . " "
                . __(
                "If you modify working documents, you will not be capable any more of analyzing the papers you have already distributed!"
                )
        );
    }

    # deja des MEP fabriquees ?
    $self->{project}->{_layout}->begin_transaction('DMAJ');
    my $pc = $self->{project}->{_layout}->pages_count;
    $self->{project}->{_layout}->end_transaction('DMAJ');
    if ( $pc > 0 ) {
        if ( !$sur ) {
            push(
                $self->{messages},
                __( "Layouts are already calculated for the current documents."
                    )
                    . " "
                    . __(
                    "Updating working documents, the layouts will become obsolete and will thus be erased."
                    )
            );
        }

        $self->clear_processing('mep:');
    }

    # new layout document : XY (from LaTeX)

    if ( $self->{config}->get('doc_setting') =~ /\.pdf$/ ) {
        $self->{config}
            ->set_project_option_to_default( 'doc_setting', 'FORCE' );
    }

    # check for filter dependencies

    my $filter_register
        = ( "AMC::Filter::register::" . $self->{config}->get('filter') )
        ->new();

    my $check = $filter_register->check_dependencies();

    if ( !$check->{'ok'} ) {
        my $message = sprintf(
            __( "To handle properly <i>%s</i> files, AMC needs the following components, that are currently missing:"
            ),
            $filter_register->name()
        ) . "\n";
        for my $k (qw/latex_packages commands fonts/) {
            if ( @{ $check->{$k} } ) {
                $message .= "<b>" . $component_name{$k} . "</b> ";
                if ( $k eq 'fonts' ) {
                    $message .= join( ', ',
                        map { @{ $_->{'family'} } } @{ $check->{$k} } );
                }
                else {
                    $message .= join( ', ', @{ $check->{$k} } );
                }
                $message .= "\n";
            }
        }
        $message
            .= __("Install these components on your system and try again.");

        push( $self->{errors}, $message );
        $self->{status} = 412;

        return (0);
    }

    # set options from filter:

    if ( $self->{config}->get('filter') ) {
        $filter_register->set_oo( $self->{config} );
        $filter_register->configure();
    }

    # remove pre-existing DOC-corrected.pdf (built by AMC-annotate)
    my $pdf_corrected = $self->{config}->get_absolute("DOC-corrected.pdf");
    if ( -f $pdf_corrected ) {
        debug "Removing pre-existing $pdf_corrected";    #error
        unlink($pdf_corrected);
    }

    #
    my $mode_s = 's[';
    $mode_s .= 's' if ( $self->{config}->get('prepare_solution') );
    $mode_s .= 'c' if ( $self->{config}->get('prepare_catalog') );
    $mode_s .= ']';
    $mode_s .= 'k' if ( $self->{config}->get('prepare_indiv_solution') );
    commande(
        'commande' => [
            "auto-multiple-choice",
            "prepare",
            "--with",
            $self->moteur_latex(),
            "--filter",
            $self->{config}->get('filter'),
            "--filtered-source",
            $self->{config}->get_absolute('filtered_source'),
            "--debug",
            debug_file(),
            "--out-sujet",
            $self->{config}->get_absolute('doc_question'),
            "--out-corrige",
            $self->{config}->get_absolute('doc_solution'),
            "--out-corrige-indiv",
            $self->{config}->get_absolute('doc_indiv_solution'),
            "--out-catalog",
            $self->{config}->get_absolute('doc_catalog'),
            "--out-calage",
            $self->{config}->get_absolute('doc_setting'),
            "--mode",
            $mode_s,
            "--n-copies",
            $self->{config}->get('nombre_copies'),
            $self->{config}->get_absolute('texsrc'),
            "--prefix",
            $self->{config}->get_absolute('%PROJET/'),
            "--latex-stdout",
        ],
        'signal'        => 2,
        'texte'         => __ "Documents update...",
        'progres.id'    => 'MAJ',
        'progres.pulse' => 0.01,
        'fin'           => sub {
            my ( $c, %data ) = @_;

            if ( $data{cancelled} ) {
                debug "Prepare documents: CANCELLED!";
            }
            else {
                my @err  = $c->erreurs();
                my @warn = $c->warnings();
                if ( @err || @warn ) {
                    debug "Errors preparing documents!";
                    my $message
                        = __("Problems while processing the source file.")
                        . " "
                        . __(
                        "You have to correct the source file and re-run documents update."
                        );
                    if (@err) {
                        $message
                            .= "\n\n"
                            . __("<b>Errors</b>") . "\n"
                            . join( "\n",
                            map { format_markup($_) }
                                ( @err[ 0 .. mini( 9, $#err ) ] ) )
                            . (
                            $#err > 9
                            ? "\n\n<i>("
                                . __("Only first ten errors written")
                                . ")</i>"
                            : ""
                            );
                    }
                    if (@warn) {
                        $message
                            .= "\n\n"
                            . __("<b>Warnings</b>") . "\n"
                            . join( "\n",
                            map { format_markup($_) }
                                ( @warn[ 0 .. mini( 9, $#warn ) ] ) )
                            . (
                            $#warn > 9
                            ? "\n\n<i>("
                                . __("Only first ten warnings written")
                                . ")</i>"
                            : ""
                            );
                    }
                    $message .= "\n\n" .

# TRANSLATORS: Here, %s will be replaced with the translation of "Command output details", and refers to the small expandable part at the bottom of AMC main window, where one can see the output of the commands lauched by AMC.
                        sprintf(
                        __("See also the processing log in '%s' below."),

# TRANSLATORS: Title of the small expandable part at the bottom of AMC main window, where one can see the output of the commands lauched by AMC.
                        __ "Command output details"
                        );
                    $message
                        .= " "
                        . __(
                        "Use LaTeX editor or latex command for a precise diagnosis."
                        ) if ( $self->{config}->get('filter') eq 'latex' );

                    push( $self->{errors}, $message );
                    $self->{status} = 412;

                }
                else {
                    print( 'documents', __ "Documents have been prepared" );

                    # verif que tout y est
                    my $ok = 1;
                    for (qw/question solution setting/) {
                        $ok = 0
                            if (
                            !-f $self->{config}->get_absolute( 'doc_' . $_ )
                            );
                    }
                    if ($ok) {
                        debug "All documents are successfully generated";

                        # set project option from filter requests
                        my %vars = $c->variables;
                        for my $k ( keys %vars ) {
                            if ( $k =~ /^project:(.*)/ ) {
                                debug "Configuration: $k = $vars{$k}";
                                $self->{config}->set( $k, $vars{$k} );
                            }
                        }
                    }
                }

                # Try to guess the best place to write question
                # scores when annotating. This option can be
                # changed later in the Edit/Preferences window.
                my $ap = 'marges';
                if ( $c->variable('scorezones') ) {
                    $ap = 'zones';
                }
                elsif ( $c->variable('ensemble') ) {
                    $ap = 'cases';
                }
                $self->{config}->set( 'annote_position', $ap );

                my $ensemble
                    = $c->variable('ensemble') && !$c->variable('outsidebox');
                if ( ( $ensemble || $c->variable('insidebox') )
                    && $self->{config}->get('seuil') < 0.4 )
                {
                    push(
                        $self->{messages},
                        (   $ensemble
                            ? __(
                                "Your question has a separate answers sheet.")
                                . " "
                                . __(
                                "In this case, letters are shown inside boxes."
                                )
                            : __(
                                "Your question is set to present labels inside the boxes to be ticked."
                            )
                            )
                            . " "

# TRANSLATORS: Here, %s will be replaced with the translation of "darkness threshold".
                            . __(
                            "For better ticking detection, ask students to fill out completely boxes, and choose parameter \"%s\" around 0.86 for this project."
                            )
                            . " "
                            . __(
                            "At the moment, this parameter is set to %.02f.")

# TRANSLATORS: This parameter is the ratio of dark pixels number over total pixels number inside box above which a box is considered to be ticked.
                        ,
                        __ "darkness threshold",
                        $self->{config}->get('seuil')
                    );
                    $self->{config}->set( 'seuil',    0.86 );
                    $self->{config}->set( 'seuil_up', 1.0 );
                }
                $self->detecte_documents();
            }
        }
    );
}

sub sujet_impressions_ok {
    my $self = shift;
    my $os   = 'none';
    my @e    = ();

    if ( $self->{config}->get('methode_impression') eq 'file' ) {

        if ( !$self->{config}->get('options_impression/repertoire') ) {
            debug "Print to file : no destination...";
            $self->{config}->set( 'options_impression/repertoire', '' );
        }
        else {
            my $path = $self->{config}
                ->get_absolute('options_impression/repertoire');
            mkdir($path) if ( !-e $path );
        }
    }

    debug "Printing: " . join( ",", @e );    #error

    if ( !@e ) {

        # No page selected:
        push(
            $self->{messages},
            __("You did not select any exam to print...")
        );
        return ();
    }

    if ( 1 + $#e <= 10 ) {

        # Less than 10 pages selected: is it a mistake?

        $self->{project}->{'_layout'}->begin_read_transaction('pPFP');
        my $max_p    = $self->{project}->{'_layout'}->max_enter();
        my $students = $self->{project}->{'_layout'}->students_count();
        $self->{project}->{'_layout'}->end_transaction('pPFP');

        if ( $max_p > 1 ) {

            # Some sheets have more than one enter-page: multiple scans
            # are not supported...

            return () if ( $resp eq 'no' );
        }
        elsif ( $students <= 10 ) {
            if ( $self->{config}->get('auto_capture_mode') != 1 ) {

                # This looks strange: a few sheets printed, a few sheets
                # generated, and photocopy mode not selected yet. Ask the
                # user if he wants to select this mode now.
                push(
                    $self->{messages},
                    __("You selected only a few sheets to print.") . "\n"
                        . "<b>"
                        . __(
                        "Are you going to photocopy some printed subjects before giving them to the students?"
                        )
                        . "</b>\n"
                        . __(
                        "If so, the corresponding option will be set for this project."
                        )
                );
                $self->{config}->set( 'auto_capture_mode', 1 );
            }
        }
    }

    if ( $self->{config}->get('options_impression/print_answersheet') eq
        'first' )
    {
        # This options needs pdftk!
        if ( $self->{config}->get('print_extract_with') ne 'pdftk' ) {
            if ( commande_accessible('pdftk') ) {
                push(
                    $self->{messages},

# TRANSLATORS: the two %s will be replaced by the translations of "Answer sheet first" and "Extracting method".
                    sprintf(
                        __( "You selected the '%s' option, that uses 'pdftk', so the %s has been set to 'pdftk' for you."
                        ),
                        __("Answer sheet first"),
                        __("Extracting method")
                    )
                );

                $self->{config}->set( "print_extract_with", 'pdftk' );
            }
            else {
                push(
                    $self->{messages},
                    sprintf(
                        __( "You selected the '%s' option, but this option needs 'pdftk' to be installed on your system. Please install it and try again."
                        ),
                        __ "Answer sheet first"
                    )
                );

                return ();
            }
        }
    }

    my $fh = File::Temp->new(
        TEMPLATE => "nums-XXXXXX",
        TMPDIR   => 1,
        UNLINK   => 1
    );
    print $fh join( "\n", @e ) . "\n";
    $fh->seek( 0, SEEK_END );

    my @o_answer = ( '--no-split', '--no-answer-first' );
    if ( $self->{config}->get('options_impression/print_answersheet') eq
        'split' )
    {
        @o_answer = ( '--split', '--no-answer-first' );
    }
    elsif ( $self->{config}->get('options_impression/print_answersheet') eq
        'first' )
    {
        @o_answer = ( '--answer-first', '--no-split' );
    }

    commande(
        'commande' => [
            "auto-multiple-choice",
            "imprime",
            "--methode",
            $self->{config}->get('methode_impression'),
            "--imprimante",
            $self->{config}->get('imprimante'),
            "--options",
            $os,
            "--output",
            $self->{config}->get_absolute('options_impression/repertoire')
                . "/sheet-%e.pdf",
            @o_answer,
            "--print-command",
            $self->{config}->get('print_command_pdf'),
            "--sujet",
            $self->{config}->get_absolute('doc_question'),
            "--data",
            $self->{config}->get_absolute('data'),
            "--progression-id",
            'impression',
            "--progression",
            1,
            "--debug",
            debug_file(),
            "--fich-numeros",
            $fh->filename,
            "--extract-with",
            $self->{config}->get('print_extract_with'),
        ],
        'signal'     => 2,
        'texte'      => __ "Print papers one by one...",
        'progres.id' => 'impression',
        'o'          => {
            'fh'      => $fh,
            'etu'     => \@e,
            'printer' => $self->{config}->get('imprimante'),
            'method'  => $self->{config}->get('methode_impression')
        },
        'fin' => sub {
            my $c = shift;
            close( $c->{'o'}->{'fh'} );
            $self->save_state_after_printing( $c->{'o'} );
        },

    );
}

sub save_state_after_printing {
    my ( $self, $c ) = @_;
    my $st = AMC::State::new(
        'directory' => $self->{config}->get_absolute('%PROJET/') );

    $st->read();

    my @files = grep { -f $self->{config}->get_absolute($_) }
        map { $self->{config}->get( 'doc_' . $_ ) }
        (qw/question solution setting catalog/);
    push @files, $self->{config}->get_absolute('texsrc');

    push @files, $self->{config}->get_absolute('filtered_source')
        if ( -f $self->{config}->get_absolute('filtered_source') );

    if ( !$st->check_local_md5(@files) ) {
        $st = AMC::State::new(
            'directory' => $self->{config}->get_absolute('%PROJET/') );
        $st->add_local_files(@files);
    }

    $st->add_print(
        'printer' => $c->{'printer'},
        'method'  => $c->{'method'},
        'content' => join( ',', @{ $c->{'etu'} } )
    );
    $st->write();

}

sub calcule_mep {
    my $self = shift;
    if ( $self->{config}->get('doc_setting') !~ /\.xy$/ ) {

        # OLD STYLE WORKING DOCUMENTS... Not supported anymore: update!
        push(
            $self->{messages},
            __( "Working documents are in an old format, which is not supported anymore."
                )
                . " <b>"
                . __("Please generate again the working documents!") . "</b>"
        );

        return;
    }

    commande(
        'commande' => [
            "auto-multiple-choice",
            "meptex",
            "--debug",
            debug_file(),
            "--src",
            $self->{config}->get_absolute('doc_setting'),
            "--progression-id",
            'MEP',
            "--progression",
            1,
            "--data",
            $self->{config}->get_absolute('data'),
        ],
        'texte'      => __ "Detecting layouts...",
        'progres.id' => 'MEP',
        'fin'        => sub {
            my ( $c, %data ) = @_;
            $self->detecte_mep();
            if ( !$data{cancelled} ) {
                $self->{project}->{'_layout'}->begin_read_transaction('PGCN');
                my $c = $self->{project}->{'_layout'}->pages_count();
                $self->{project}->{'_layout'}->end_transaction('PGCN');
                if ( $c < 1 ) {

                    # avertissement...
                    push(
                        $self->{errors},
                        __("No layout detected.") . " "
                            . __(
                            "<b>Don't go through the examination</b> before fixing this problem, otherwise you won't be able to use AMC for correction."
                            )
                    );
                    $self->{status} = 412;
                }
                else {

                }
            }
        }
    );
}

sub analyse_call {
    my $self = shift;
    my (%oo) = @_;

    # make temporary file with the list of images to analyse

    my $fh = File::Temp->new(
        TEMPLATE => "liste-XXXXXX",
        TMPDIR   => 1,
        UNLINK   => 1
    );
    print $fh join( "\n", @{ $oo{'f'} } ) . "\n";
    $fh->seek( 0, SEEK_END );

    if ( $oo{'getimages'} ) {
        my @args = (
            "--progression-id", 'analyse',
            "--list",           $fh->filename,
            "--debug",          debug_file(),
            "--vector-density", $self->{config}->get('vector_scan_density'),
        );
        push @args, "--copy-to", $oo{'copy'} if ( $oo{'copy'} );
        push @args, "--force-convert"
            if ( $self->{config}->get("force_convert") );
        $self->{project}->{_layout}->begin_transaction('Orie');
        my $orientation = $self->{project}->{_layout}->orientation();
        $self->{project}->{_layout}->end_transaction('Orie');
        push @args, "--orientation", $orientation if ($orientation);

        debug "Target orientation: $orientation";

        commande(
            'commande'   => [ "auto-multiple-choice", "getimages", @args ],
            'signal'     => 2,
            'progres.id' => $oo{'progres'},
            'fin'        => sub {
                my ( $c, %data ) = @_;
                if ( !$data{cancelled} ) {
                    $self->analyse_call_go(
                        'liste' => $fh->filename,
                        'fh'    => $fh,
                        %oo
                    );
                }
            },
        );
    }
    else {
        $self->analyse_call_go( 'liste' => $fh->filename, 'fh' => $fh, %oo );
    }
}

sub analyse_call_go {
    my $self = shift;
    my (%oo) = @_;
    my @args = (
        "--debug",
        debug_file(),
        (   $self->{config}->get('auto_capture_mode') ? "--multiple"
            : "--no-multiple"
        ),
        "--tol-marque",
        $self->{config}->get('tolerance_marque_inf') . ','
            . $self->{config}->get('tolerance_marque_sup'),
        "--prop",
        $self->{config}->get('box_size_proportion'),
        "--bw-threshold",
        $self->{config}->get('bw_threshold'),
        "--progression-id",
        'analyse',
        "--progression",
        1,
        "--n-procs",
        $self->{config}->get('n_procs'),
        "--data",
        $self->{config}->get_absolute('data'),
        "--projet",
        $self->{config}->get_absolute('%PROJET/'),
        "--cr",
        $self->{config}->get_absolute('cr'),
        "--liste-fichiers",
        $oo{'liste'},
        (   $self->{config}->get('ignore_red') ? "--ignore-red"
            : "--no-ignore-red"
        ),
        (   $self->{config}->get('try_three') ? "--try-three"
            : "--no-try-three"
        ),
    );

    push @args, "--pre-allocate", $oo{'allocate'} if ( $oo{'allocate'} );

    # Diagnostic image file ?

    if ( $oo{'diagnostic'} ) {
        push @args, "--debug-image-dir",
            $self->{config}->get_absolute('%PROJET/cr/diagnostic');
    }

    # call AMC-analyse

    commande(
        'commande'   => [ "auto-multiple-choice", "analyse", @args ],
        'signal'     => 2,
        'texte'      => $oo{'text'},
        'progres.id' => $oo{'progres'},
        'o'          => { 'fh' => $oo{'fh'} },
        'fin'        => $oo{'fin'},
    );
}

sub valide_liste {
    my $self = shift;
    my %oo   = @_;
    debug "* valide_liste";

    if ( defined( $oo{'set'} ) && !$oo{'nomodif'} ) {
        $self->{config}->set( 'listeetudiants',
            $self->{config}->{shortcuts}->relatif( $oo{'set'} ) );
    }

    my $fl = $self->{config}->get_absolute('listeetudiants');
    $fl = '' if ( !$self->{config}->get('listeetudiants') );

    my $fn = $fl;
    $fn =~ s/.*\///;

    $self->{project}->{_students_list} = AMC::NamesFile::new(
        $fl,
        'encodage'    => bon_encodage('liste'),
        'identifiant' => csv_build_name(),
    );
    my ( $err, $errlig ) = $self->{project}->{_students_list}->errors();

    if ($err) {

        if ( !$oo{'noinfo'} ) {
            push(
                $self->{errors},
                sprintf(
                    __ "Unsuitable names file: %d errors, first on line %d.",
                    $err, $errlig
                )
            );
            $self->{status} = 412;
        }
    }
    else {
        # problems with ID (name/surname)
        my $e = $self->{project}->{_students_list}->problem('ID.empty');
        if ( $e > 0 ) {
            debug "NamesFile: $e empty IDs";
            push(
                $self->{messages},
                sprintf( __
                        "Found %d empty names in names file <i>%s</i>. Check that <b>name</b> or <b>surname</b> column is present, and always filled.",
                    $e, $fl )
                    . " "
                    . __ "Edit the names file to correct it, and re-read."
            );
        }
        else {
            my $d = $self->{project}->{_students_list}->problem('ID.dup');
            if (@$d) {
                debug "NamesFile: duplicate IDs [" . join( ',', @$d ) . "]";
                if ( $#{$d} > 8 ) {
                    @$d = ( @{$d}[ 0 .. 8 ], '(and more)' );
                }
                push(
                    $self->{messages},
                    sprintf(
                        __
                            "Found duplicate names: <i>%s</i>. Check that all names are different.",
                        join( ', ', @$d )
                        )
                        . " "
                        . __ "Edit the names file to correct it, and re-read."
                );

            }
        }

        # transmission liste des en-tetes
        my @heads = $self->{project}->{_students_list}->heads_for_keys();
    }
    $self->assoc_state();
}

# manual association
sub associe {
    my $self = shift;
    return () if ( !$self->check_possible_assoc(0) );
    if ( -f $self->{config}->get_absolute('listeetudiants') ) {
        my $ga = AMC::Gui::Association::new(
            'cr'          => $self->{config}->get_absolute('cr'),
            'data_dir'    => $self->{config}->get_absolute('data'),
            'liste'       => $self->{config}->get_absolute('listeetudiants'),
            'liste_key'   => $self->{config}->get('liste_key'),
            'identifiant' => csv_build_name(),

            'fichier-liens'  => $self->{config}->get_absolute('association'),
            'global'         => 0,
            'assoc-ncols'    => $self->{config}->get('assoc_ncols'),
            'encodage_liste' => bon_encodage('liste'),
            'encodage_interne' => $self->{config}->get('encodage_interne'),
            'rtl'              => $self->{config}->get('annote_rtl'),
            'fin'              => sub {
                assoc_state();
            },
            'size_prefs' => (
                  $self->{config}->get('conserve_taille')
                ? $self->{config}
                : ''
            ),
        );
        if ( $ga->{'erreur'} ) {

        }
    }
    else {

        push(
            $self->{messages},
            sprintf(
                __
                    "Before associating names to papers, you must choose a students list file in paragraph \"%s\".",
                __ "Students identification"
            )
        );

    }
}

# automatic association
sub associe_auto {
    my $self = shift;
    return () if ( !check_possible_assoc(1) );

    commande(
        'commande' => [
            "auto-multiple-choice",
            "association-auto",
            pack_args(
                "--data",
                $self->{config}->get_absolute('data'),
                "--notes-id",
                $self->{config}->get('assoc_code'),
                "--liste",
                $self->{config}->get_absolute('listeetudiants'),
                "--liste-key",
                $self->{config}->get('liste_key'),
                "--csv-build-name",
                $self->csv_build_name(),
                "--encodage-liste",
                $self->bon_encodage('liste'),
                "--debug",
                debug_file(),
                (   $self->{config}->get('assoc_code') eq '<preassoc>'
                    ? "--pre-association"
                    : "--no-pre-association"
                ),
            ),
        ],
        'texte' => __ "Automatic association...",
        'fin'   => sub {
            my ( $c, %data ) = @_;
            $self->assoc_state();
            $self->assoc_resultat() if ( !$data{cancelled} );
        },
    );
}

# automatic association finished : explain what to do after
sub assoc_resultat {
    my $self = shift;
    my $mesg = 1;

    $self->{project}->{'_association'}->begin_read_transaction('ARCC');
    my ( $auto, $man, $both ) = $self->{project}->{'_association'}->counts();
    $self->{project}->{'_association'}->end_transaction('ARCC');

    push(
        $self->{messages},
        sprintf(
            __("Automatic association completed: %d students recognized."),
            $auto
            )
            .

# TRANSLATORS: Here %s and %s will be replaced with two parameters names: "Primary key from this list" and "Code name for automatic association".
            (
            $auto == 0
            ? "\n<b>"
                . sprintf(
                __("Please check \"%s\" and \"%s\" values and try again."),
                __("Primary key from this list"),
                __("Code name for automatic association")
                )

            : ""
            )
    );
}

sub noter {
    my $self = shift;
    if ( $self->{config}->get('maj_bareme') ) {
        my $mode = "b";
        my $pdf_corrected
            = $self->{config}->get_absolute('doc_indiv_solution');
        if ( -f $pdf_corrected ) {
            debug "Removing pre-existing $pdf_corrected";
            unlink($pdf_corrected);
        }
        $mode .= 'k' if ( $self->{config}->get('prepare_indiv_solution') );

        my $n_copies = $self->{config}->get('nombre_copies');
        commande(
            'commande' => [
                "auto-multiple-choice",
                "prepare",
                "--out-corrige-indiv",
                $pdf_corrected,
                "--n-copies",
                $n_copies,
                "--with",
                $self->moteur_latex(),
                "--filter",
                $self->{config}->get('filter'),
                "--filtered-source",
                $self->{config}->get_absolute('filtered_source'),
                "--debug",
                debug_file(),
                "--progression-id",
                'bareme',
                "--progression",
                1,
                "--data",
                $self->{config}->get_absolute('data'),
                "--mode",
                $mode,
                $self->{config}->get_absolute('texsrc'),
            ],
            'texte'      => __ "Extracting marking scale...",
            'fin'        => \&noter_postcorrect,
            'progres.id' => 'bareme'
        );
    }
    else {
        $self->noter_calcul( '', '' );
    }
}

sub noter_calcul {
    my $self = shift;
    my ( $postcorrect_student, $postcorrect_copy, $postcorrect_set_multiple )
        = @_;

    debug
        "Using sheet $postcorrect_student:$postcorrect_copy to get correct answers"
        if ($postcorrect_student);

    # computes marks.

    commande(
        'commande' => [
            "auto-multiple-choice", "note",
            "--debug",              debug_file(),
            "--data",               $self->{config}->get_absolute('data'),
            "--seuil",              $self->{config}->get('seuil'),
            "--seuil-up",           $self->{config}->get('seuil_up'),

            "--grain",
            $self->{config}->get('note_grain'),
            "--arrondi",
            $self->{config}->get('note_arrondi'),
            "--notemax",
            $self->{config}->get('note_max'),
            (   $self->{config}->get('note_max_plafond') ? "--plafond"
                : "--no-plafond"
            ),
            "--notenull",
            $self->{config}->get('note_null'),
            "--notemin",
            $self->{config}->get('note_min'),
            "--postcorrect-student",
            $postcorrect_student,
            "--postcorrect-copy",
            $postcorrect_copy,
            (   $postcorrect_set_multiple ? "--postcorrect-set-multiple"
                : "--no-postcorrect-set-multiple"
            ),

            "--progression-id",
            'notation',
            "--progression",
            1,
        ],
        'signal'     => 2,
        'texte'      => __ "Computing marks...",
        'progres.id' => 'notation',
        'fin'        => sub {
            my ( $c, %data ) = @_;
            push( $self->{messages}, __ "Grading has been completed" )
                if ( !$data{cancelled} );
            $self->noter_resultat();
        },
    );
}

sub noter_resultat {
    my $self = shift;
    $self->{project}->{'_scoring'}->begin_read_transaction('MARK');
    my $avg = $self->{project}->{'_scoring'}->average_mark;

    if ( defined($avg) ) {
        $self->{data}->{mean} = sprintf( "%.2f", $avg );
    }
    else {
        push( $self->{messages}, __("No marks computed") );
    }

    my @codes     = $self->{project}->{'_scoring'}->codes;
    my $pre_assoc = $self->{project}->{'_layout'}->pre_association();

    $self->{project}->{'_scoring'}->end_transaction('MARK');

    debug "Codes : " . join( ',', @codes );

}

sub assoc_state {
    my $self = shift;
    my $t    = '';
    if ( !-s $self->{config}->get_absolute('listeetudiants') ) {
        $t = __ "No students list file";
    }
    elsif ( !$self->{config}->get('liste_key') ) {
        $t = __ "No primary key from students list file";
    }
    else {
        $self->{project}->{'_association'}->begin_read_transaction('ARST');
        my $mc = $self->{project}->{'_association'}->missing_count;
        $self->{project}->{'_association'}->end_transaction('ARST');
        if ($mc) {
            $t = sprintf(
                ( __ "Missing identification for %d answer sheets" ),
                $mc
            );
        }
        else {
            $t = __
                "All completed answer sheets are associated with a student name";
        }
    }
    push( $self->{messages}, $t );

}

sub opt_symbole {
    my $self = shift;
    my ($s)  = @_;
    my $k    = $s;

    $k =~ s/-/_/g;
    my $type  = $self->{config}->get( 'symbole_' . $k . '_type',  'none' );
    my $color = $self->{config}->get( 'symbole_' . $k . '_color', 'red' );

    return ("$s:$type/$color");
}

sub annote_copies {
    my $self = shift;

    my $single_output = '';

    if ( $self->{config}->get('regroupement_type') eq 'ALL' ) {
        $single_output = __("All_students") . ".pdf";
    }

    commande(
        'commande' => [
            "auto-multiple-choice",
            "annotate",
            pack_args(
                "--cr",
                $self->{config}->get_absolute('cr'),
                "--project",
                $self->{config}->get_absolute('%PROJET/'),
                "--projects",
                $self->{config}->get_absolute('%PROJETS/'),
                "--data",
                $self->{config}->get_absolute('data'),
                "--subject",
                $self->{config}->get_absolute('doc_question'),
                "--corrected",
                $self->{config}->get_absolute('doc_indiv_solution'),
                "--filename-model",
                $self->{config}->get('modele_regroupement'),
                (   $self->{config}->get('ascii_filenames') ? "--force-ascii"
                    : "--no-force-ascii"
                ),
                "--single-output",
                $single_output,
                "--sort",
                $self->{config}->get('export_sort'),
                "--id-file",
                $id_file,
                "--debug",
                debug_file(),
                "--progression-id",
                'annotate',
                "--progression",
                1,
                "--line-width",
                $self->{config}->get('symboles_trait'),
                "--font-name",
                $self->{config}->get('annote_font_name'),
                "--symbols",
                join( ',', map { opt_symbole($_); } (qw/0-0 0-1 1-0 1-1/) ),
                (   $self->{config}->get('symboles_indicatives')
                    ? "--indicatives"
                    : "--no-indicatives"
                ),
                "--position",
                $self->{config}->get('annote_position'),
                "--dist-to-box",
                $self->{config}->get('annote_ecart'),
                "--n-digits",
                $self->{config}->get('annote_chsign'),
                "--verdict",
                $self->{config}->get('verdict'),
                "--verdict-question",
                $self->{config}->get('verdict_q'),
                "--verdict-question-cancelled",
                $self->{config}->get('verdict_qc'),
                "--names-file",
                $self->{config}->get_absolute('listeetudiants'),
                "--names-encoding",
                $self->bon_encodage('liste'),
                "--csv-build-name",
                $self->csv_build_name(),
                ( $self->{config}->get('annote_rtl') ? "--rtl" : "--no-rtl" ),
                "--changes-only",
                1, "--sort",
                $self->{config}->get('export_sort'),
                "--compose",
                $self->{config}->get('regroupement_compose'),
                "--n-copies",
                $self->{config}->get('nombre_copies'),
                "--src",
                $self->{config}->get_absolute('texsrc'),
                "--with",
                $self->moteur_latex(),
                "--filter",
                $self->{config}->get('filter'),
                "--filtered-source",
                $self->{config}->get_absolute('filtered_source'),
                "--embedded-max-size",
                $self->{config}->get('embedded_max_size'),
                "--embedded-format",
                $self->{config}->get('embedded_format'),
                "--embedded-jpeg-quality",
                $self->{config}->get('embedded_jpeg_quality'),
            )
        ],
        'fin' => sub {
            my ( $c, %data );

            push( $self->{messages}, __ "Annotations have been completed" )
                if ( !$data{cancelled} );
        },
    );
}

sub annotate_papers {

    $self->maj_export();

    $self->annote_copies;
}

sub detecte_documents {
    my $self = shift;
    $self->check_document( $self->{config}->get_absolute('doc_question'),
        'question' );
    $self->check_document( $self->{config}->get_absolute('doc_solution'),
        'solution' );
    $self->check_document(
        $self->{config}->get_absolute('doc_indiv_solution'),
        'indiv_solution' );
    $self->check_document( $self->{config}->get_absolute('doc_catalog'),
        'catalog' );
    my $s = file_maj( map { $self->{config}->get_absolute( 'doc_' . $_ ) }
            (qw/question setting/) );
    if ( $s eq 'UNREADABLE' ) {
        $s = __("Working documents are not readable");
    }
    elsif ( $s eq 'NOTFOUND' ) {
        $s = __("No working documents");
    }
    else {
        $s = __("Working documents last update:") . " " . $s;
    }

    push( $self->{messages}, $s );
}

sub detecte_mep {
    my $self = shift;
    $self->{project}->{'_layout'}->begin_read_transaction('LAYO');
    $self->{project}->{'_mep_defauts'}
        = { $self->{project}->{'_layout'}->defects() };
    my $c = $self->{project}->{'_layout'}->pages_count;
    $self->{project}->{'_layout'}->end_transaction('LAYO');
    my @def = ( keys %{ $self->{project}->{'_mep_defauts'} } );
    if (@def) {

        $self->mep_warnings();
    }
    my $s;
    if ( $c < 1 ) {
        $s = __("No layout");
    }
    else {
        $s = sprintf( __("Processed %d pages"), $c );
        if (@def) {
            $s .= ", " . __("but some defects were detected.");

        }
        else {
            $s .= '.';
        }
    }

    push( $self->{messages}, $s );
}

my %defect_text = (
    'NO_NAME' => __(
        "The \\namefield command is not used. Writing subjects without name field is not recommended"
    ),
    'SEVERAL_NAMES' => __(
        "The \\namefield command is used several times for the same subject. This should not be the case, as each student should write his name only once"
    ),
    'NO_BOX'              => __("No box to be ticked"),
    'DIFFERENT_POSITIONS' => __(
        "The corner marks and binary boxes are not at the same location on all pages"
    ),
);

sub mep_warnings {
    my $self = shift;
    my $m    = '';
    my @def  = ( keys %{ $self->{project}->{'_mep_defauts'} } );
    if (@def) {
        $m
            = __(
            "Some potential defects were detected for this subject. Correct them in the source and update the working documents."
            );
        for my $k ( keys %defect_text ) {
            my $dd = $self->{project}->{'_mep_defauts'}->{$k};
            if ($dd) {
                if ( $k eq 'DIFFERENT_POSITIONS' ) {
                    $m
                        .= "\n<b>"
                        . $defect_text{$k} . "</b> "
                        . sprintf(
                        __('(See for example pages %s and %s)'),
                        pageids_string( $dd->{'student_a'}, $dd->{'page_a'} ),
                        pageids_string( $dd->{'student_b'}, $dd->{'page_b'} )
                        ) . '.';
                }
                else {
                    my @e = sort { $a <=> $b } ( @{$dd} );
                    if (@e) {
                        $m
                            .= "\n<b>"
                            . $defect_text{$k} . "</b> "
                            . sprintf(
                            __( '(Concerns %1$d exams, see for example sheet %2$d)'
                            ),
                            1 + $#e,
                            $e[0]
                            ) . '.';
                    }
                }
            }
        }
    }
    else {
        # should not be possible to go there...
        return ();
    }

    push( $self->{messages}, $m );

}

sub clear_processing {
    my $self    = shift;
    my ($steps) = @_;
    my $next    = '';
    my %s       = ();
    for my $k (qw/doc mep capture mark assoc/) {
        if ( $steps =~ /\b$k:/ ) {
            $next = 1;
            $s{$k} = 1;
        }
        elsif ( $next || $steps =~ /\b$k\b/ ) {
            $s{$k} = 1;
        }
    }

    if ( $s{'doc'} ) {
        for (qw/question solution setting catalog/) {
            my $f = $self->{config}->get_absolute( 'doc_' . $_ );
            unlink($f) if ( -f $f );
        }
        $self->detecte_documents();
    }

    delete( $s{'doc'} );
    return () if ( !%s );

    # data to remove...

    $self->{project}->{'_data'}->begin_transaction('CLPR');

    if ( $s{'mep'} ) {
        $self->{project}->{_layout}->clear_all;
    }

    if ( $s{'capture'} ) {
        $self->{project}->{_capture}->clear_all;
    }

    if ( $s{'mark'} ) {
        $self->{project}->{'_scoring'}->clear_strategy;
        $self->{project}->{'_scoring'}->clear_score;
    }

    if ( $s{'assoc'} ) {
        $self->{project}->{_association}->clear;
    }

    $self->{project}->{'_data'}->end_transaction('CLPR');

    # files to remove...

    if ( $s{'capture'} ) {

        # remove zooms
        remove_tree(
            $self->{config}->get_absolute('%PROJET/cr/zooms'),
            { 'verbose' => 0, 'safe' => 1, 'keep_root' => 1 }
        );

        # remove namefield extractions and page layout image
        my $crdir = $self->{config}->get_absolute('%PROJET/cr');
        opendir( my $dh, $crdir );
        my @cap_files = grep {/^(name-|page-)/} readdir($dh);
        closedir($dh);
        for (@cap_files) {
            unlink "$crdir/$_";
        }
    }

    # update gui...

    if ( $s{'mep'} ) {
        $self->detecte_mep();
    }
    if ( $s{'capture'} ) {
        $self->detecte_analyse();
    }
    if ( $s{'mark'} ) {
        $self->noter_resultat();
    }
    if ( $s{'assoc'} ) {
        $self->assoc_state();
    }
}

sub detecte_analyse {
    my $self = shift;
    $self->{project}->{'_capture'}->begin_read_transaction('ADCP');
    my $n = $self->{project}->{'_capture'}->n_pages;

    my %r = $self->{project}->{'_capture'}->counts;

    $r{'npages'} = $n;

    my $failed_nb = $self->{project}->{'_capture'}
        ->sql_single( $self->{project}->{'_capture'}->statement('failedNb') );

    $self->{project}->{'_capture'}->end_transaction('ADCP');

    # resume

    my $tt = '';
    if ( $r{'incomplete'} ) {
        $tt
            = sprintf( __
                "Data capture from %d complete papers and %d incomplete papers",
            $r{'complete'}, $r{'incomplete'} );

    }
    elsif ( $r{'complete'} ) {
        $tt = sprintf(
            __("Data capture from %d complete papers"),
            $r{'complete'}
        );

    }
    else {
   # TRANSLATORS: this text points out that no data capture has been made yet.
        $tt = sprintf( __ "No data" );

    }

    push( $self->{messages}, $tt );

    if ( $failed_nb <= 0 ) {
        if ( $r{'complete'} ) {
            $tt = __ "All scans were properly recognized.";

        }
        else {
            $tt = "";

        }

    }
    else {
        $tt = sprintf( __ "%d scans were not recognized.", $failed_nb );

    }

    push( $self->{messages}, $tt );

    return ( \%r );
}

sub show_missing_pages {
    my $self = shift;
    $self->{project}->{'_capture'}->begin_read_transaction('cSMP');
    my %r = $self->{project}->{'_capture'}->counts;
    $self->{project}->{'_capture'}->end_transaction('cSMP');

    my $l  = '';
    my @sc = ();
    for my $p ( @{ $r{'missing'} } ) {
        if ( $sc[0] != $p->{'student'} || $sc[1] != $p->{'copy'} ) {
            @sc = ( $p->{'student'}, $p->{'copy'} );
            $l .= "\n";
        }
        $l .= "  "
            . pageids_string( $p->{'student'}, $p->{'page'}, $p->{'copy'} );
    }

    push(
        $self->{messages},
        __("Pages that miss data capture to complete students sheets:")
            . "</b>"
            . $l
    );
}

sub update_unrecognized {
    my $self = shift;
    $self->{project}->{'_capture'}->begin_read_transaction('UNRC');
    my $failed
        = $self->{project}->{'_capture'}->dbh->selectall_arrayref(
        $self->{project}->{'_capture'}->statement('failedList'),
        { Slice => {} } );
    $self->{project}->{'_capture'}->end_transaction('UNRC');

    for my $ff (@$failed) {

        my $f = $ff->{'filename'};
        $f =~ s:.*/::;
        my ( undef, undef, $scan_n )
            = splitpath( $self->{config}->get_absolute( $ff->{'filename'} ) );
        my $preproc_file
            = $self->{config}->get_absolute('%PROJET/cr/diagnostic') . "/"
            . $scan_n . ".png";
        push( $self->{data}, ( $f, $ff->{'filename'}, $preproc_file ) );
    }
}

sub unrecognized_delete {
    my $self = shift;
    $self->{project}->{'_capture'}->begin_transaction('rmUN');
    for my $s (@sel) {

        $self->{project}->{'_capture'}->statement('deleteFailed')
            ->execute($file);
        unlink $self->{config}->get_absolute($file);
    }

    $self->detecte_analyse();
    $self->{project}->{'_capture'}->end_transaction('rmUN');
}
sub set_source_tex {
    my ($importe)=@_;

    importe_source() if($importe);
    valide_source_tex();
}
sub valide_source_tex {
    my $self = shift;
    debug "* valide_source_tex";

    if ( !$self->{config}->get('filter') ) {
        $self->{config}->set( 'filter',
            best_filter_for_file( $self->{config}->get_absolute('texsrc') ) );
    }

    $self->detecte_documents();
}

sub n_fich {
    my ($dir) = @_;

    if ( opendir( NFICH, $dir ) ) {
        my @f = grep { !/^\./ } readdir(NFICH);
        closedir(NFICH);

        return ( 1 + $#f, "$dir/$f[0]" );
    }
    else {
        debug("N_FICH : Can't open directory $dir : $!");
        return (0);
    }
}

sub unzip_to_temp {
    my ($file) = @_;

    my $temp_dir = tempdir( DIR => tmpdir(), CLEANUP => 1 );
    my $error = 0;

    my @cmd;

    if ( $file =~ /\.zip$/i ) {
        @cmd = ( "unzip", "-d", $temp_dir, $file );
    }
    else {
        @cmd = ( "tar", "-x", "-v", "-z", "-f", $file, "-C", $temp_dir );
    }

    debug "Extracting archive files\nFROM: $file\nWITH: " . join( ' ', @cmd );
    if ( open( UNZIP, "-|", @cmd ) ) {
        while (<UNZIP>) {
            debug $_;
        }
        close(UNZIP);
    }
    else {
        $error = $!;
    }

    return ( $temp_dir, $error );
}

sub valide_projet {
    my $self = shift;

    $self->set_source_tex();

    $self->{project}->{'_data'}
        = AMC::Data->new( $self->{config}->get_absolute('data'),
        'progress' => \%w );
    for (qw/layout capture scoring association report/) {
        $self->{project}->{ '_' . $_ }
            = $self->{project}->{'_data'}->module($_);
    }

    $self->{project}->{_students_list} = AMC::NamesFile::new();

    $self->detecte_mep();
    $self->detecte_analyse( 'premier' => 1 );

    $self->noter_resultat();

    $self->valide_liste( 'noinfo' => 1, 'nomodif' => 1 );

}

sub create_project {
    my $self = shift;
    # creation du repertoire et des sous-repertoires de projet
    for my $sous ( '',
        qw:cr cr/corrections cr/corrections/jpg cr/corrections/pdf cr/zooms cr/diagnostic data scans exports:
        )
    {
        my $rep = $self->{config}->get('rep_projets') . "/$proj/$sous";
        if ( !-x $rep ) {
            debug "Creating directory $rep...";
            mkdir($rep);
        }
    }
    $self->valide_projet();
    return (1);

}

my %ROUTING = (
    '/quiz/add'                     => 'create_project',
    '/quiz/delete'                  => 'delete_project',
    '/quiz/upload/latex'            => 'set_source',
    '/quiz/upload/zip'              => 'set_source',
    '/document/generate'            => 'doc_maj',
    '/document/latex'               => 'get_source',
    '/sheet/upload'                 => 'scan_upload',
    '/sheet/delete'                 => '',
    '/sheet/delete/unknown'         => '',
    '/sheet/delete/unknown/student' => '',
    '/sheet/'                       => '',
    '/association/'                 => 'assoc_resultat',
    '/association/associate/all'    => 'assoc_auto',
    '/association/associate/one'    => 'associe',
    '/grading'                      => 'export',
    '/grading/grade'                => 'noter_calcul',
    '/grading/stats'                => 'noter_resultat',
    '/annotation/'                  => '',
    '/annotation/annotate'          => 'annote_copies',
    '/annotation/pdf'               => '',

);

my %PARAMS = (
    "answer-first"             => 'options_impression/print_answersheet',
    "arrondi"                  => 'note_arrondi',
    "assoc-ncols"              => 'assoc_ncols',
    "bw-threshold"             => 'bw_threshold',
    "changes-only"             => 'change_only',
    "compose"                  => 'regroupement_compose',
    "csv-build-name"           => 'csv_build_name',
    "dist-to-box"              => 'annote_ecart',
    "embedded-format"          => 'embedded_format',
    "embedded-jpeg-quality"    => 'embedded_jpeg_quality',
    "embedded-max-size"        => 'embedded_max_size',
    "encodage_interne"         => 'encodage_interne',
    "extract-with"             => 'print_extract_with',
    "filename-model"           => 'modele_regroupement',
    "filter"                   => 'filter',
    "font-name"                => 'annote_font_name',
    "force-ascii"              => 'ascii_filenames',
    "force-convert"            => "force_convert",
    "global"                   => "global",
    "grain"                    => 'note_grain',
    "identifiant"              => 'csv_build_name',
    "ignore-red"               => 'ignore_red',
    "imprimante"               => 'imprimante',
    "indicative"               => 'symboles_indicatives',
    "line-width"               => 'symboles_trait',
    "liste-key"                => 'liste_key',
    "liste_key"                => 'liste_key',
    "methode"                  => 'methode_impression',
    "module"                   => 'module',
    "multiple"                 => 'auto_capture_mode',
    "n-copies"                 => 'nombre_copies',
    "n-digits"                 => 'annote_chsign',
    "n-procs"                  => 'n_procs',
    "notemax"                  => 'note_max',
    "notemin"                  => 'note_min',
    "notenull"                 => 'note_null',
    "notes-id"                 => 'assoc_code',
    "plafond"                  => 'note_max_plafond',
    "position"                 => 'annote_position',
    "postcorrect-copy"         => 'postcorrect_copy',
    "postcorrect-set-multiple" => 'postcorrect_set_multiple',
    "postcorrect-student"      => 'postcorrect_student',
    "pre-association"          => 'assoc_code',
    "print-command"            => 'print_command_pdf',
    "prop"                     => 'box_size_proportion',
    "rtl"                      => 'annote_rtl',
    "seuil"                    => 'seuil',
    "seuil-up"                 => 'seuil_up',
    "single-output"            => 'single_output',
    "sort"                     => 'export_sort',
    "split"                    => 'options_impression/print_answersheet',
    "tol-marque"     => 'tolerance_marque_inf' . ',' . 'tolerance_marque_sup',
    "try-three"      => 'try_three',
    "useall"         => 'export_include_abs',
    "vector-density" => 'vector_scan_density',
    "verdict"        => 'verdict',
    "verdict-question"           => 'verdict_q',
    "verdict-question-cancelled" => 'verdict_qc'
);
my @POST = ( 'filecode', 'idnumber','students','file');

sub new {
    my $class = shift;
    my ( $dir, $ip, $request, $uploads ) = @_;
    my $self = { status => 200, errors => (), messages => (), data => () };
    $self->{config} = AMC::Config::new(
        shortcuts => AMC::Path::new( home_dir => $dir ),
        home_dir  => $dir,
        o_dir     => $dir,
    );
    my $base_url = $self->{config}->get('general:api_url');
    if ( defined($ip) ) {    #not config script
        if ( defined($request) ) {
            if ( ref $request eq 'HASH' ) {
                my $project_dir = $ip . ":" . $request->{apikey}
                    if defined( $request->{apikey} );
                my $globalkey = $request->{globalkey}
                    if defined( $request->{globalkey} );
            }
            elsif ( $request
                =~ /^\Q$base_url\E\/image\/([^\/]*)\/([^\.]*)\.(.*)$/ )
            {
                my $project_dir = $prefix . ":" . $1;
                $self->{wanted_file} = "%PROJET/cr/" . $2 . ".jpg"
                    if ( $3 eq 'jpg' );
            }

            if ( defined($project_dir) ) {
                $self->{project}->{'nom'} = $project_dir;
                $self->{config}->{shortcuts}
                    ->set( project_name => $project_dir );
                if ( -d $self->get_shortcut('%PROJET') ) {
                    $self->{config}->open_project($project_dir);
                    if defined( $request->{apikey} ) {
                        my @config_key = values %PARAMS;
                        my @cli_key    = keys %PARAMS;
                        for my $k ( keys %{$request} ) {
                            $self->set_config( $k, $request->{$k} )
                                if ( defined $config_key[$k] );
                            $self->set_config( $PARAMS{$k}, $request->{$k} )
                                if ( defined $cli_key[$k] );
                            $self->{$k} = $request->{$k} ) if ( defined $POST[$k] );

                        }
                        $self->{uploads} = $uploads ) if ( defined $uploads );
                    }
                }
                elsif (
                    defined($globalkey)
                    && ( $globalkey eq
                        $self->{config}->get('general:api_secret') )
                    )
                {
                    $self->{status} = 404;
                    push( $self->{messages}, "Not Found" );
                }
                else {
                    $self->{status} = 403;
                    push( $self->{messages}, "Forbidden" );
                }
            }
        }
        else {    # image

        }
    }
    bless $self, $class;
    return $self;
}

sub get_file {
    my ( $self, $file ) = @_;
    if ( $self->{status} == 403 ) {
        return [
            403, [ 'Content-Type' => 'text/plain', 'Content-Length' => 9 ],
            ['forbidden']
        ];
    }
    if ( defined($file) ) {    #download
        my $base_url = $self->{config}->get('general:api_url');
        if (   ( $file =~ /^\Q$base_url\E\/download\/(.*)$/ )
            && ( -d $self->get_shortcut( "%PROJET/" . $1 ) ) )
        {
            return $self->get_shortcut( $self->{wanted_file} );
        }
        else {
            return [
                404,
                [ 'Content-Type' => 'text/plain', 'Content-Length' => 9 ],
                ['not found']
            ];
        }
    }
    elsif ( defined( $self->{wanted_file} )
        && ( -d $self->get_shortcut( $self->{wanted_file} ) ) )
    {    #image
        return $self->get_shortcut( $self->{wanted_file} );
    }
    else {
        return [
            404, [ 'Content-Type' => 'text/plain', 'Content-Length' => 9 ],
            ['not found']
        ];
    }

}

sub DESTROY {
    my $self = shift;
    if ( $self->{project}->{'nom'} ) {

        $self->{config}->close_project();

    }
    return (1);
}

sub to_content {
    my $self    = shift;
    my $content = '';
    my $type    = 'text/plain';
    if (   ( ( scalar $self->{errors} ) == 0 )
        && ( ( keys $self->{data} ) == 0 ) )
    {
        $content = join( "\n", $self->{messages} );

    }
    else {
        $type    = 'application/json';
        $self->{status} = 500 if ( ( scalar $self->{errors} ) > 0 );
        $content = encode_json(
            {   status  => $self->{status},
                message => join( "\n", $self->{messages} ),
                errors  => $self->{errors},
                data    => $self->{data}
            }
        );
    }
    return ( $self->{status}, $type, length($content), $content );
}

sub status {
    my $self = shift;
    return $self->{status};
}

sub get_config {
    my ( $self, $key ) = @_;
    return $self->{config}->get($key);
}

sub set_config {
    my ( $self, $key, $value ) = @_;
    $self->{config}->set( 'project:' . $key, $value );
}

sub get_shortcut {
    my ( $self, $shortcut ) = @_;
    return ( $self->{config}->{shortcuts}->absolu($shortcut) );
}

sub call {
    my ( $self, $action ) = @_;
    my $base_url = $self->{config}->get('general:api_url');
    $action =~ /^\Q$base_url\E(.*)$/;
    my $method = $ROUTING{$1};
    if ( $self->can($method) ) {
        $self->$method;
    }
    else {
        $self->{status} = 400;
        push( $self->{messages}, "Bad Request" );
    }

}
