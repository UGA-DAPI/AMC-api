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

package AMC::Api;

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

use AMC::Config;
use AMC::CommandeApi;
use JSON;
use MIME::Base64 qw(decode_base64);
use URI;

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

# Reads filter plugins list

my @filter_modules = perl_module_search('AMC::Filter::register');
for my $m (@filter_modules) {
    load("AMC::Filter::register::$m");
}
@filter_modules = sort {
    "AMC::Filter::register::$a"->weight <=>
        "AMC::Filter::register::$b"->weight
} @filter_modules;

sub best_filter_for_file {
    my ($file) = @_;
    my $mmax   = '';
    my $max    = -10;
    for my $m (@filter_modules) {
        my $c = "AMC::Filter::register::$m"->claim($file);
        if ( $c > $max ) {
            $max  = $c;
            $mmax = $m;
        }
    }
    return ($mmax);
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

sub id2file {
    my $self = shift;
    my ( $id, $prefix, $extension ) = (@_);
    $id =~ s/\+//g;
    $id =~ s/\//-/g;
    return (
        $self->{config}->get_absolute('cr') . "/$prefix-$id.$extension" );
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
    $code = 'grades' if ( !$code );
    utf8::encode($code);
    my $output
        = $self->{config}->get_shortcut( '%PROJET/exports/' . $code . $ext );
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
                if ( $format == 'json' ) {
                    open my $fh, "<", $output;
                    my $json = <$fh>;
                    close $fh;
                    $self->{data} = decode_json($json);
                }

                # shows export messages
                push @{ $self->{errors} },   $c->erreurs();
                push @{ $self->{messages} }, $c->warning();

            }
            else {
                push @{ $self->{messages} },
                    sprintf(
                    __ "Export to %s did not work: file not created...",
                    $output
                    );
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

sub remove_project {
    my $self  = shift;
    my ($force) = @_;
    if ( $self->{globalkey} ) {
        push(
            @{ $self->{messages} },
            sprintf(
                __("You asked to remove project <b>%s</b>.") . " "
                    . __(
                    "This will permanently erase all the files of this project, including the source file as well as all the files you put in the directory of this project, as the scans for example."
                    )
                    . " "
                    . __("Is this really what you want?"),
                $proj
            )
        );

        if ( !$force ) {
            return;
        }

        debug "Removing project $proj !";

        # suppression effective des fichiers...

        my $dir = $self->get_shortcut('%PROJET');
        if ( -d $dir ) {
            remove_tree( $dir,
                { 'verbose' => 0, 'safe' => 1, 'keep_root' => 0 } );
        }
        else {
            debug "No directory $dir";
        }
    }
}
my %component_name = (
    'latex_packages' => __("LaTeX packages:"),
    'commands'       => __("Commands:"),
    'fonts'          => __("Fonts:"),
);

sub doc_maj {
    my ($self) = (@_);
    if ( $self->{project}->{'_capture'}->n_pages_transaction() > 0 ) {
        push(
            @{ $self->{messages} },
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
        if ( !$self->{force} ) {
            push(
                @{ $self->{messages} },
                __( "Layouts are already calculated for the current documents."
                    )
                    . " "
                    . __(
                    "Updating working documents, the layouts will become obsolete and will thus be erased."
                    )
            );
            return ();
        }
        else {
            $self->clear_processing('mep:');
        }

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

        push( @{ $self->{errors} }, $message );
        $self->{status} = 500;

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

                    push( @{ $self->{errors} }, $message );
                    $self->{status} = 500;

                }
                else {
                    push(
                        @{ $self->{messages} },
                        __ "Documents have been prepared"
                    );

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
                        @{ $self->{messages} },
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
            }
            $self->detecte_documents();
        }
    );
}

sub sujet_impressions_ok {
    my $self = shift;
    my $os   = 'none';

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

    # Less than 10 pages selected: is it a mistake?

    $self->{project}->{'_layout'}->begin_read_transaction('pPFP');
    my $max_p    = $self->{project}->{'_layout'}->max_enter();
    my $students = $self->{project}->{'_layout'}->students_count();
    $self->{project}->{'_layout'}->end_transaction('pPFP');

    if ( $max_p > 1 ) {

        # Some sheets have more than one enter-page: multiple scans
        # are not supported...
        push(
            @{ $self->{messages} },
            __("You selected only a few sheets to print.") . "\n"
                . __(
                "As students are requested to write on more than one page, you must create as many exam sheets as necessary for all your students, with different sheets numbers, and print them all."
                )
                . " "
                . __(
                "If you print one or several sheets and photocopy them to have enough for all the students, <b>you won't be able to continue with AMC!</b>"
                )
                . "\n"
                . __("Do you want to print the selected sheets anyway?"),
        );
        return ();    # if ( $resp eq 'no' );
    }
    elsif ( $students <= 10 ) {
        if ( $self->{config}->get('auto_capture_mode') != 1 ) {

            # This looks strange: a few sheets printed, a few sheets
            # generated, and photocopy mode not selected yet. Ask the
            # user if he wants to select this mode now.
            push(
                @{ $self->{messages} },
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

    if ( $self->{config}->get('options_impression/print_answersheet') eq
        'first' )
    {
        # This options needs pdftk!
        if ( $self->{config}->get('print_extract_with') ne 'pdftk' ) {
            if ( commande_accessible('pdftk') ) {
                push(
                    @{ $self->{messages} },

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
                    @{ $self->{messages} },
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
            "--extract-with",
            $self->{config}->get('print_extract_with'),
        ],
        'signal'     => 2,
        'texte'      => __ "Print papers one by one...",
        'progres.id' => 'impression',
        'o'          => {
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
        'method'  => $c->{'method'}
    );
    $st->write();

}

sub calcule_mep {
    my $self = shift;
    if ( $self->{config}->get('doc_setting') !~ /\.xy$/ ) {

        # OLD STYLE WORKING DOCUMENTS... Not supported anymore: update!
        push(
            @{ $self->{messages} },
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
                        @{ $self->{errors} },
                        __("No layout detected.") . " "
                            . __(
                            "<b>Don't go through the examination</b> before fixing this problem, otherwise you won't be able to use AMC for correction."
                            )
                    );
                    $self->{status} = 500;
                }

            }
        }
    );
}

sub check_auto_capture_mode {
    my $self = shift;
    $self->{project}->{'_capture'}->begin_read_transaction('ckac');
    my $n = $self->{project}->{'_capture'}->n_copies;
    if ( $n > 0 && $self->{config}->get('auto_capture_mode') < 0 ) {

        # the auto_capture_mode (sheets photocopied or not) is not set,
        # but some capture has already been done. This looks weird, but
        # it can be the case if captures were made with an old AMC
        # version, or if project parameters have not been saved...
        # So we try to detect the correct value from the capture data.
        $self->{config}->set( 'auto_capture_mode',
            ( $self->{project}->{'_capture'}->n_photocopy() > 0 ? 1 : 0 ) );
    }
    $self->{project}->{'_capture'}->end_transaction('ckac');
    return ($n);
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

sub saisie_auto_ok {
    my $self = shift;
    my @f    = ();
    $self->{uploads}->each( sub { push @f, $_[1]->{'tempname'} } );
    my $copie = $self->{config}->get('copie_scans');

    clear_old( 'diagnostic', $self->get_shortcut('%PROJET/cr/diagnostic') );

    analyse_call(
        'f'         => \@f,
        'getimages' => 1,
        'copy'     => ( $copie ? $self->get_shortcut('%PROJET/scans/') : '' ),
        'text'     => __("Automatic data capture..."),
        'progres'  => 'analyse',
        'allocate' => (
              $self->{config}->get('allocate_ids')
            ? $self->{config}->get('allocate_ids')
            : 0
        ),
        'fin' => sub {
            my ( $c, %data ) = @_;
            close( $c->{'o'}->{'fh'} );
            $self->detecte_analyse();
            $self->assoc_state();
            if ( !$data{cancelled} ) {
                push(
                    @{ $self->{messages} },
                    __ "Automatic data capture has been completed"
                );
            }
        },
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
                @{ $self->{errors} },
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
                @{ $self->{messages} },
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
                    @{ $self->{messages} },
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

sub check_possible_assoc {
    my $self = shift;
    my ($code) = @_;
    if ( !-s $self->{config}->get_absolute('listeetudiants') ) {
        push(
            @{ $self->{messages} },

# TRANSLATORS: Here, %s will be replaced with the name of the tab "Data capture".
            sprintf(
                __
                    "Before associating names to papers, you must choose a students list file in tab \"%s\".",
                __ "Data capture"
            )
        );

    }
    elsif ( !$self->{config}->get('liste_key') ) {

        push(
            @{ $self->{messages} },
            __( "Please choose a key from primary keys in students list before association."
            )
        );

    }
    elsif ( $code && !$self->{config}->get('assoc_code') ) {

        push(
            @{ $self->{messages} },
            __( "Please choose a code (made with LaTeX command \\AMCcode) before automatic association."
            )
        );

    }
    else {
        return (1);
    }
    return (0);
}

# manual association
sub associe {
    my $self = shift;
    return () if ( !$self->check_possible_assoc(0) );
    return () if ( !$self->{filecode} );
    return () if ( !$self->{idnumber} );
    if ( -f $self->{config}->get_absolute('listeetudiants') ) {

        if ( $self->{filecode} =~ /^([0-9]+)-([0-9]+)/ ) {
            $self->{project}->{_assoc}
                ->set_manual( $1, $2, $self->{idnumber} );
        }
    }
    else {

        push(
            @{ $self->{messages} },
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
        @{ $self->{messages} },
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
            'fin'        => \&self->noter_calcul,
            'progres.id' => 'bareme'
        );
    }
    else {
        $self->noter_calcul( '', '' );
    }
}

sub noter_postcorrect {
    my $self = shift;
    my ( $c, %data ) = @_;

    detecte_documents();

    return if ( $data{cancelled} );

    # check marking scale data: in PostCorrect mode, ask for a sheet
    # number to get right answers from...

    if ( $self->{project}->{'_scoring'}
        ->variable_transaction('postcorrect_flag') )
    {

        debug "PostCorrect option ON";

        # gets available sheet ids

        %postcorrect_ids = ();

        $self->{project}->{'_capture'}->begin_read_transaction('PCex');
        my $sth = $self->{project}->{'_capture'}->statement('studentCopies');
        $sth->execute;
        while ( my $sc = $sth->fetchrow_hashref ) {
            $postcorrect_student_min = $sc->{'student'}
                if ( !defined($postcorrect_student_min) );
            $postcorrect_ids{ $sc->{'student'} }->{ $sc->{'copy'} } = 1;
            $postcorrect_student_max = $sc->{'student'};
        }
        $self->{project}->{'_capture'}->end_transaction('PCex');

        # ask user for a choice

        if ( $self->{config}->get('postcorrect_student') ) {

        }
        else {
            $self->{config}
                ->set( 'postcorrect_student', $postcorrect_student_min );
            my @c = sort { $a <=> $b }
                ( keys %{ $postcorrect_ids{$postcorrect_student_min} } );
            $self->{config}->set( 'postcorrect_copy', $c[0] );
        }

    }
    else {
        noter_calcul( '', '' );
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
            push( @{ $self->{messages} }, __ "Grading has been completed" )
                if ( !$data{cancelled} );
            $self->noter_resultat();
        },
    );
}

sub noter_resultat {
    my $self = shift;
    $self->{project}->{'_scoring'}->begin_read_transaction('MARK');
    my $avg = $self->{project}->{'_scoring'}->average_mark;
    my @marks = $self->{project}->{'_scoring'}->marks;

    if ( defined($avg) ) {
        $self->{data}->{mean} = sprintf( "%.2f", $avg );
    }
    else {
        push( @{ $self->{messages} }, __("No marks computed") );
    }

    $self->{data}->{workforce} = $self->{project}->{'_scoring'}->marksCount;
    $self->{project}->{'_scoring'}->end_transaction('MARK');

    my @sortmarks = sort  {$a <=> $b} @marks;
    my $mid = int @sortmarks/2;
    if (@sortmarks % 2) {
        $self->{data}->{median} = $sortmarks[ $mid ];
    } else {
        $self->{data}->{median} = ($sortmarks[$mid-1] + $sortmarks[$mid])/2;
    } 
    my %counts;
    ++$counts{$_} for @marks;
    my @mode = sort { $counts{$a} <=> $counts{$b} } keys %counts;
    $self->{data}->{mode} = $mode[0];
    $self->{data}->{range} = $sortmarks[0]. '-'. $sortmarks[-1]; 

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
    push( @{ $self->{messages} }, $t );

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

sub select_students {
    my $self = shift;

    $self->{project}->{'_capture'}->begin_read_transaction('gSLi');
    my $key = $self->{project}->{'_association'}->variable('key_in_list');
    for my $sc ( $self->{project}->{'_capture'}->student_copies ) {
        my $manual = $self->{project}->{'_association'}->get_manual(@$c);
        my $auto   = $self->{project}->{'_association'}->get_auto(@$c);
        my $type   = 'none';
        my $idnumber;
        if ( defined($manual) ) {
            $idnumber = $manual;
            $type     = "manual";
        }
        elsif ( defined($auto) ) {
            $idnumber = $auto;
            $type     = "auto";
        }
        my %iter = (
            filecode => studentids_string(@$sc),
            idnumber => $idnumber,
            type     => $type,
            url      => $self->get_url(
                "name-" . studentids_string_filename(@sc) . ".jpg"
            ),
        );
        push @{ $self->{data} }, %iter;
    }
    $self->{project}->{'_capture'}->end_transaction('gSLi');

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
                (   $self->{config}->get('ascii_filenames')
                    ? "--force-ascii"
                    : "--no-force-ascii"
                ),
                "--single-output",
                $single_output,
                "--sort",
                $self->{config}->get('export_sort'),

                #"--id-file",
                #$id_file,
                "--debug",
                debug_file(),
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

            push(
                @{ $self->{messages} },
                __ "Annotations have been completed"
            ) if ( !$data{cancelled} );
        },
    );
}

sub annotate_papers {

    $self->{config}->set( 'project:regroupement_type', 'STUDENTS' );
    $self->annote_copies;
}

sub annotate_all {

    $self->{config}->set( 'project:regroupement_type', 'ALL' );
    $self->annote_copies;
}

sub file_maj {
    my (@f)     = @_;
    my $present = 1;
    my $oldest  = 0;
    for my $file (@f) {
        if ( $file && -f $file ) {
            if ( -r $file ) {
                my @s = stat($file);
                $oldest = $s[9] if ( $s[9] > $oldest );
            }
            else {
                return ('UNREADABLE');
            }
        }
        else {
            return ('NOTFOUND');
        }
    }
    return ( format_date($oldest) );
}

sub detecte_documents {
    my $self = shift;

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

    push( @{ $self->{messages} }, $s );
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

    push( @{ $self->{messages} }, $s );
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

    push( @{ $self->{messages} }, $m );

}

sub clear_processing {
    my $self    = shift;
    my ($steps) = @_;
    my $next    = '';
    my %s       = ();
    for my $k (qw/doc mep capture zooms mark assoc annoted/) {
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
            $self->get_shortcut('%PROJET/cr/zooms'),
            { 'verbose' => 0, 'safe' => 1, 'keep_root' => 1 }
        );
        remove_tree( $self->get_shortcut('%PROJET/scans/'),
            { 'verbose' => 0, 'safe' => 1, 'keep_root' => 1 } );

        # remove namefield extractions and page layout image
        my $crdir = $self->{config}->get_absolute('%PROJET/cr');
        opendir( my $dh, $crdir );
        my @cap_files = grep {/^(name-|page-)/} readdir($dh);
        closedir($dh);
        for (@cap_files) {
            unlink "$crdir/$_";
        }
    }
    if ( $s{'zooms'} ) {
        remove_tree(
            $self->get_shortcut('%PROJET/cr/zooms'),
            { 'verbose' => 0, 'safe' => 1, 'keep_root' => 1 }
        );
    }

    if ( $s{'annoted'} ) {
        remove_tree(
            $self->get_shortcut('%PROJET/cr/corrections/jpg'),
            { 'verbose' => 0, 'safe' => 1, 'keep_root' => 1 }
        );
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
    $self->{data}->{recognized} = $r{'complete'};

    my $tt = '';
    if ( $r{'incomplete'} ) {
        $tt
            = sprintf( __
                "Data capture from %d complete papers and %d incomplete papers",
            $r{'complete'}, $r{'incomplete'} );
        $self->show_missing_pages();

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

    push( @{ $self->{messages} }, $tt );

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
        $self->update_unrecognized();
    }

    push( @{ $self->{messages} }, $tt );

    return;
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
        @{ $self->{messages} },
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

        push(
            @{ $self->{data}->{unrecognized} },
            ( $ff->{'filename'} => "diagnostic/" . $scan_n . ".png" )
        );
    }
}

sub unrecognized_delete {
    my $self = shift;
    my $file = $self->{filecode};
    $self->{project}->{'_capture'}->begin_transaction('rmUN');

    $self->{project}->{'_capture'}->statement('deleteFailed')->execute($file);
    unlink $self->{config}->get_absolute($file);

    $self->detecte_analyse();
    $self->{project}->{'_capture'}->end_transaction('rmUN');
}

sub unrecognized_delete_all {
    my $self = shift;
    my $file = "%PROJET/cr/diagnostic/" . $self->{filecode};
    $self->{project}->{'_capture'}->begin_transaction('rmUNA');
    my $failed
        = $self->{project}->{'_capture'}->dbh->selectall_arrayref(
        $self->{project}->{'_capture'}->statement('failedList'),
        { Slice => {} } );
    for my $ff (@$failed) {
        $self->{project}->{'_capture'}->statement('deleteFailed')
            ->execute( $ff->{'filename'} );
        unlink $self->{config}->get_absolute( $ff->{'filename'} );
    }
    $self->{project}->{'_capture'}->end_transaction('rmUNA');
    $self->detecte_analyse();
}

sub set_source_tex {
    my $self = shift;
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

sub source_latex_choisir {
    my $self     = shift;
    my $texsrc   = '';
    my $filename = 'source';
    my $filetemp;
    my $dir = $self->get_shortcut('%PROJET');
    my $ext = '';

    # choisir un fichier deja present
    if ( defined $self->{file} ) {
        my $content = decode_base64( $self->{file} );
        if ($h
            && (   $h =~ /\\usepackage.*\{automultiplechoice\}/
                || $h =~ /\\documentclass\{/ )
            )
        {
            $ext = '.tex';
        }
        elsif ( $h && $h =~ /^\s*\#\s*AMC-TXT/ ) {
            $ext = '.txt';
        }
        else {
            $ext      = '.zip';
            $dir      = tempdir( DIR => tmpdir(), CLEANUP => 1 );
            $filetemp = $dir . $filename . $ext;
        }
        open( OUT,
            ">:encoding(" . $self->{'out.encodage'} . ")",
            $dir . $filename . $ext
        );
        print OUT $content;
        close(OUT);
    }
    elsif ( defined $self->{uploads} ) {
        my $upload = $req->uploads->[0];
        $filetemp = $upload->path;
        if ( $upload->content_type == 'text/plain' ) {
            $ext = '.txt';
            move( $filetemp, $dir . $filename . $ext );
        }
        elsif ( $upload->content_type == 'application/x-tex' ) {
            $ext = '.tex';
            move( $filetemp, $dir . $filename . $ext );
        }

    }
    if ( $ext == '.txt' || $ext == '.tex' ) {
        $self->{config}->set( 'project:texsrc',
            $self->{config}->{shortcuts}
                ->relatif( $filename . $ext, $self->{project}->{'nom'} ) );
    }
    else {

        # cree un repertoire temporaire pour dezipper

        my ( $temp_dir, $rv ) = unzip_to_temp($filetemp);

        my ( $n, $suivant ) = n_fich($temp_dir);

        if ( $rv || $n == 0 ) {
            push(
                @{ $self->{messages} },
                sprintf(
                    __ "Nothing extracted from archive %s. Check it.",
                    $fich
                )
            );
        }
        else {
            # unzip OK
            # vire les repertoires intermediaires :

            while ( $n == 1 && -d $suivant ) {
                debug "Changing root directory : $suivant";
                $temp_dir = $suivant;
                ( $n, $suivant ) = n_fich($temp_dir);
            }

            # bouge les fichiers la ou il faut

            my $hd = $dir;

            mkdir($hd) if ( !-e $hd );

            my @archive_files;

            if ( opendir( MVR, $temp_dir ) ) {
                @archive_files = grep { !/^\./ } readdir(MVR);
                closedir(MVR);
            }
            else {
                debug("ARCHIVE : Can't open $temp_dir : $!");
            }

            my $latex;

            for my $ff (@archive_files) {
                debug "Moving to project: $ff";
                if ( $ff =~ /\.tex$/i ) {
                    $latex = $ff;
                    if ( $oo{'decode'} ) {
                        debug "Decoding $ff...";
                        move( "$temp_dir/$ff", "$temp_dir/$ff.0enc" );
                        copy_latex( "$temp_dir/$ff.0enc", "$temp_dir/$ff" );
                    }
                }
                if ( system( "mv", "$temp_dir/$ff", "$hd/$ff" ) != 0 ) {
                    debug "ERR: Move failed: $temp_dir/$ff --> $hd/$ff -- $!";
                    debug "(already exists)" if ( -e "$hd/$ff" );
                }
            }

            if ($latex) {
                $self->{config}->set( 'project:texsrc',
                    $self->get_shortcut("%PROJET/$latex") );
                debug "LaTeX found : $latex";
            }
        }
    }
    $self->valide_source_tex();

}

# copie en changeant eventuellement d'encodage
sub copy_latex {
    my ( $src, $dest ) = @_;

    # 1) reperage du inputenc dans le source
    my $i = '';
    open( SRC, $src );
LIG: while (<SRC>) {
        s/%.*//;
        if (/\\usepackage\[([^\]]*)\]\{inputenc\}/) {
            $i = $1;
            last LIG;
        }
    }
    close(SRC);

    my $ie = get_enc($i);
    my $id = get_enc( $self->{config}->get('encodage_latex') );
    if ( $ie && $id && $ie->{'iso'} ne $id->{'iso'} ) {
        debug "Reencoding $ie->{'iso'} => $id->{'iso'}";
        open( SRC, "<:encoding($ie->{'iso'})", $src ) or return ('');
        open( DEST, ">:encoding($id->{'iso'})", $dest )
            or close(SRC), return ('');
        while (<SRC>) {
            chomp;
            s/\\usepackage\[([^\]]*)\]\{inputenc\}/\\usepackage[$id->{'inputenc'}]{inputenc}/;
            print DEST "$_\n";
        }
        close(DEST);
        close(SRC);
        return (1);
    }
    else {
        return ( copy( $src, $dest ) );
    }
}

sub importe_source {
    my $self = shift;
    my ( $fxa, $fxb, $fb ) = splitpath( $self->{config}->get('texsrc') );
    my $dest = $self->get_shortcut($fb);

    # fichier deja dans le repertoire projet...
    return () if ( is_local( $self->{config}->get('texsrc'), 1 ) );

    if ( -f $dest ) {
        push(
            @{ $self->{messages} },
            __( "File %s already exists in project directory: do you wnant to replace it?"
                )
                . " "
                . __(
                "Click yes to replace it and loose pre-existing contents, or No to cancel source file import."
                ),
            $fb
        );

        if ( !$self->{force} ) {
            return (0);
        }
    }

    if ( copy_latex( $self->{config}->get_absolute('texsrc'), $dest ) ) {
        $self->{config}->set( 'project:texsrc',
            $self->{config}->{shortcuts}->relatif($dest) );
        $self->valide_source_tex();
        push(
            @{ $self->{messages} },
            __("The source file has been copied to project directory.") . " "
                . sprintf(
                __
                    "You can now edit it with button \"%s\" or with any editor.",
                __ "Edit source file"
                )
        );

    }
    else {
        push( @{ $self->{messages} }, __ "Error copying source file: %s",
            $! );
    }
}

sub valide_projet {
    my $self = shift;

    $self->set_source_tex();

    $self->{project}->{'_data'}
        = AMC::Data->new( $self->{config}->get_absolute('data') );
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

my $email_sl;
my $email_key;
my $email_r;

sub project_email_name {
    my $self = shift;
    my ($markup) = @_;
    my $pn
        = (    $self->{config}->get('nom_examen')
            || $self->{config}->get('code_examen')
            || $self->{project}->{'nom'} );
    if ($markup) {
        return ( $pn eq $self->{project}->{'nom'} ? "<b>$pn</b>" : $pn );
    }
    else {
        return ($pn);
    }
}

sub send_emails {
    my $self = shift;

    # are there some annotated answer sheets to send?

    $self->{project}->{'_report'}->begin_read_transaction('emNU');
    my $n = $self->{project}->{'_report'}->type_count(REPORT_ANNOTATED_PDF);
    my $n_annotated = $self->{project}->{'_capture'}->annotated_count();
    $self->{project}->{'_report'}->end_transaction('emNU');

    if ( $n == 0 ) {
        push(
            @{ $self->{messages} },
            __("There are no annotated corrected answer sheets to send.")
                . " "
                . (
                $n_annotated > 0
                ? __(
                    "Please group the annotated sheets to PDF files to be able to send them."
                    )
                : __(
                    "Please annotate answer sheets and group them to PDF files to be able to send them."
                )
                )
        );

        return ();
    }

    # check perl modules availibility

    my @needs_module = (
        qw/Email::Address Email::MIME
            Email::Sender Email::Sender::Simple/
    );
    if ( $self->{config}->get('email_transport') eq 'sendmail' ) {
        push @needs_module, 'Email::Sender::Transport::Sendmail';
    }
    elsif ( $self->{config}->get('email_transport') eq 'SMTP' ) {
        push @needs_module, 'Email::Sender::Transport::SMTP';
    }
    my @manque = ();
    for my $m (@needs_module) {
        if ( !check_install( module => $m ) ) {
            push @manque, $m;
        }
    }
    if (@manque) {
        debug 'Mailing: Needs perl modules ' . join( ', ', @manque );

        push(
            @{ $self->{messages} },
            sprintf(
                __( "Sending emails requires some perl modules that are not installed: %s. Please install these modules and try again."
                ),
                '<b>' . join( ', ', @manque ) . '</b>'
            )
        );

        return ();
    }

    load Email::Address;

    # then check a correct sender address has been set

    my @sa = Email::Address->parse( $self->{config}->get('email_sender') );

    if ( !@sa ) {
        my $message;
        if ( $self->{config}->get('email_sender') ) {
            $message .= sprintf(
                __("The email address you entered (%s) is not correct."),
                $self->{config}->get('email_sender')
                )
                . "\n"
                . __
                "Please edit your preferences to correct your email address.";
        }
        else {
            $message .= __("You did not enter your email address.") . "\n"
                . __ "Please edit the preferences to set your email address.";
        }
        push( @{ $self->{messages} }, $message );

        return ();
    }

    # Now check (if applicable) that sendmail path is ok

    if (   $self->{config}->get('email_transport') eq 'sendmail'
        && $self->{config}->get('email_sendmail_path')
        && !-f $self->{config}->get('email_sendmail_path') )
    {
        push(
            @{ $self->{messages} },
            sprintf(
                __( "The <i>sendmail</i> program cannot be found at the location you specified in the preferences (%s). Please update your configuration."
                ),
                $self->{config}->get('email_sendmail_path')
            )
        );

        return ();
    }

    # find columns with emails in the students list file

    my %cols_email
        = $self->{project}->{_students_list}
        ->heads_count( sub { my @a = Email::Address->parse(@_); return (@a) }
        );
    my @cols = grep { $cols_email{$_} > 0 } ( keys %cols_email );

    if ( !@cols ) {
        push(
            @{ $self->{messages} },
            __
                "No email addresses has been found in the students list file. You need to write the students addresses in a column of this file."
        );

        return ();
    }

    # which is the best column ?

    my $nmax    = 0;
    my $col_max = '';

    for (@cols) {
        if ( $cols_email{$_} > $nmax ) {
            $nmax    = $cols_email{$_};
            $col_max = $_;
        }
    }

    $self->{config}->set( 'project:email_col', $col_max )
        if ( !$self->{config}->get('email_col') );

    $self->{project}->{'_report'}->begin_read_transaction('emCC');
    $email_key = $self->{project}->{'_association'}->variable('key_in_list');
    $email_r   = $self->{project}->{'_report'}
        ->get_associated_type(REPORT_ANNOTATED_PDF);

    $self->{emails_failed} = [
        map { $_->{id} }
        grep { $_->{mail_status} == REPORT_MAIL_FAILED } (@$email_r)
    ];

    $self->{project}->{'_report'}->end_transaction('emCC');

    $self->{'attachments_expander'}
        = ( @{ $self->{config}->get('email_attachment') } ? 1 : 0 );

    # are all attachments present?
    my @missing = grep { !-f $self->get_shortcut($_) }
        ( @{ $self->{config}->get('email_attachment') } );
    if (@missing) {
        push(
            @{ $self->{messages} },
            __( "Some files you asked to be attached to the emails are missing:"
                )
                . "\n"
                . join( "\n", @missing ) . "\n"
                . __(
                "Please create them or remove them from the list of attached files."
                )
        );
        return ();
    }

    # writes the list of copies to send in a temporary file
    my $fh = File::Temp->new(
        TEMPLATE => "ids-XXXXXX",
        TMPDIR   => 1,
        UNLINK   => 1
    );
    print $fh join( "\n", @ids ) . "\n";
    $fh->seek( 0, SEEK_END );

    my @mailing_args = (
        "--project",        $self->get_shortcut('%PROJET/'),
        "--project-name",   $self->project_email_name(),
        "--students-list",  $self->{config}->get_absolute('listeetudiants'),
        "--list-encoding",  $self->bon_encodage('liste'),
        "--csv-build-name", $self->csv_build_name(),

        #"--ids-file",$fh->filename,
        "--email-column",
        $self->{config}->get('email_col'),
        "--sender",
        $self->{config}->get('email_sender'),
        "--subject",
        $self->{config}->get('email_subject'),
        "--text",
        $self->{config}->get('email_text'),
        "--text-content-type",
        (   $self->{config}->get('email_use_html')
            ? 'text/html'
            : 'text/plain'
        ),
        "--transport",
        $self->{config}->get('email_transport'),
        "--sendmail-path",
        $self->{config}->get('email_sendmail_path'),
        "--smtp-host",
        $self->{config}->get('email_smtp_host'),
        "--smtp-port",
        $self->{config}->get('email_smtp_port'),
        "--cc",
        $self->{config}->get('email_cc'),
        "--bcc",
        $self->{config}->get('email_bcc'),
        "--delay",
        $self->{config}->get('email_delay'),
    );

    for ( @{ $self->{config}->get('email_attachment') } ) {
        push @mailing_args, "--attach", $self->get_shortcut($_);
    }

    commande(
        'commande' => [
            "auto-multiple-choice",
            "mailing",
            pack_args(
                @mailing_args, "--debug",
                debug_file(),  "--progression-id",
                'mailing',     "--progression",
                1,             "--log",
                $self->get_shortcut('mailing.log'),
            ),
        ],
        'progres.id' => 'mailing',
        'texte'      => __ "Sending emails...",
        'o'          => { 'fh' => $fh },
        'fin'        => sub {
            my ( $c, %data ) = @_;
            close( $c->{'o'}->{'fh'} );

            my $ok     = $c->variable('OK')     || 0;
            my $failed = $c->variable('FAILED') || 0;
            my @message;
            push @message, "<b>" . ( __ "Cancelled." ) . "</b>"
                if ( $data{cancelled} );
            push @message, sprintf( __ "%d message(s) has been sent.", $ok );
            if ( $failed > 0 ) {
                push @message,
                      "<b>"
                    . sprintf( "%d message(s) could not be sent.", $failed )
                    . "</b>";
            }
            push( @{ $self->{messages} }, join( "\n", @message ) );

        },
    );
}

sub create_project {
    my $self = shift;
    my $proj = $self->{project}->{'nom'};
    if ( $self->{globalkey} ) {

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
    }

}

my %ROUTING = (
    '/quiz/add'                     => 'create_project',
    '/quiz/delete'                  => 'remove_project',
    '/quiz/upload/latex'            => 'source_latex_choisir',
    '/quiz/upload/zip'              => 'source_latex_choisir',
    '/document'                     => 'get_doc',
    '/document/generate'            => 'doc_maj',
    '/document/latex'               => 'get_source',
    '/sheet/upload'                 => 'saisie_auto_ok',
    '/sheet/delete'                 => 'sheet_delete',
    '/sheet/delete/unknown'         => 'unrecognized_delete_all',
    '/sheet/delete/unknown/student' => 'unrecognized_delete',
    '/sheet/'                       => 'detecte_analyse',
    '/association/'                 => 'select_students',
    '/association/associate/all'    => 'associe_auto',
    '/association/associate/one'    => 'associe',
    '/grading'                      => 'get_export',
    '/grading/generate'             => 'export_csv_ods',
    '/grading/json'                 => 'export_json',
    '/grading/grade'                => 'noter',
    '/grading/stats'                => 'noter_resultat',
    '/annotation/'                  => 'get_annotation',
    '/annotation/annotate'          => 'annotate_papers',
    '/annotation/pdf'               => 'annotate_all',

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
my @POST = ( 'filecode', 'idnumber', 'students', 'file', 'url_return' );

sub new {
    my $class = shift;
    my ( $dir, $request, $post ) = @_;
    my $self = { status => 200, errors => [], messages => [], data => [] };
    $self->{config} = AMC::Config->new(
        shortcuts => AMC::Path::new( home_dir => $dir ),
        home_dir  => $dir,
        o_dir     => $dir,
    );
    my $base_url = $self->{config}->get('global:api_url');
    if ( defined($request) ) {    #not config script
        if ( defined($post) ) {
            my $project_dir = $request->address . ":" . $post->{apikey}
                if defined( $post->{apikey} );
            $self->{globalkey}
                = $post->{globalkey} eq
                $self->{config}->get('global:api_secret')
                if defined( $request->{globalkey} );
        }
        elsif ( $request->path_info
            =~ /^\Q$base_url\E\/image\/([^\/]*)\/([^\.]*)\.(.*)$/ )
        {
            my $project_dir = $request->address . ":" . $1;
            $self->{wanted_file} = "%PROJET/cr/" . $2 . $3
                if ( $3 eq 'jpg' || $3 eq 'png' );
        }
        if ( defined($project_dir) ) {
            $self->{project}->{'nom'} = $project_dir;
            $self->{config}->{shortcuts}->set( project_name => $project_dir );
            if ( -d $self->get_shortcut('%PROJET') ) {
                $self->{config}->open_project($project_dir);
                if ( defined( $post->{apikey} ) ) {
                    my @config_key = values %PARAMS;
                    my @cli_key    = keys %PARAMS;
                    for my $k ( keys %{$post} ) {
                        $self->set_config( 'project:' . $k, $post->{$k} )
                            if ( defined $config_key[$k] );
                        $self->set_config( 'project:' . $PARAMS{$k},
                            $post->{$k} )
                            if ( defined $cli_key[$k] );
                        $self->{$k} = $post->{$k}
                            if ( defined $POST[$k] );

                    }
                    $self->{uploads} = $request->uploads
                        if ( defined $request->uploads );
                    $self->{server}
                        = $request->scheme . "://" . $request->uri->host;
                }
            }
            elsif ( defined( $self->{globalkey} )
                && $self->{globalkey} )
            {
                $self->{status} = 404;
                push( @{ $self->{messages} }, "Not Found" );
            }
            else {
                $self->{status} = 403;
                push( @{ $self->{messages} }, "Forbidden" );
            }
        }
    }
    bless $self, $class;
    return $self;
}

sub get_file {
    my ( $self, $file ) = (@_);
    if ( $self->{status} == 403 ) {
        return [
            403, [ 'Content-Type' => 'text/plain', 'Content-Length' => 9 ],
            ['forbidden']
        ];
    }
    if ( defined($file) ) {    #download
        my $base_url = $self->{config}->get('global:api_url');
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

sub get_url {
    my ( $self, $type, $file ) = (@_);
    my $url = $self->{server};
    if ( $type == "/download" ) {    #download

        $url .= "/download/";
    }
    else {
        $url .= "/image/" . $self->{apikey} . "/";
    }
    $url .= $file;
    return $url;
}

sub get_doc {
    my $self = shift;
    for (qw/question solution catalog/) {
        my $f = $self->get_absolute( 'doc_' . $_ );
        $self->{data}->{$_}
            = $self->get_url( $self->get_config( 'doc_' . $_ ) )
            if ( -f $f );
    }
    $self->{data}->{zip} = $config->get_url('documents.zip')
        if ( -f $self->get_shortcut('%PROJET/documents.zip') );
}

sub get_export {
    my $self = shift;
    for (qw/CSV ods/) {
        my $ext     = "AMC::Export::register::$format"->extension();
        if ( !$ext ) {
            $ext = lc($format);
        }
        my $code = $self->{config}->get('code_examen');
        $code = 'grades' if ( !$code );
        utf8::encode($code);
        my $f = $self->{config}->get_shortcut( '%PROJET/exports/' . $code . $ext );
        $self->{data}->{$ext}
            = $self->get_url( '/exports/' . $code . $ext ) if ( -f $f );
    }
}

sub generate_zip {
    my $self    = shift;
    my $zipfile = $config->get_shortcut('%PROJET') . '/documents.zip';

    commande(
        'commande' => [
            "zip",
            "-r",
            "--methode",
            $zipfile,
            $self->{config}->get_absolute('options_impression/repertoire')
                . '/*',

        ]
    );

}

sub generate_doc {
    my $self = shift;
    $self->doc_maj();
    $self->sujet_impressions_ok();
    $self->generate_zip();

}

sub export_json {
    my $self = shift;
    $self->{config}->set( 'project:format_export', 'json' );
    $self->exporte;
}

sub export_csv_ods {
    my $self = shift;

    for (qw/CSV ods/) {
        $self->{config}->set( 'project:format_export', $_ );
        $self->exporte;
    }

}

sub get_source {
    my $self = shift;
    my $url  = $self->{server} . "/download/";
    $url .= $self->{config}->{shortcuts}
        ->relatif( $self->{config}->get("texsrc") );
    $self->{data}->{url} = $url;
}

sub get_annotation {
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

        push(
            @{ $self->{data}->{unrecognized} },
            ( $ff->{'filename'} => "diagnostic/" . $scan_n . ".png" )
        );
    }
    my $url = $self->{server} . "/download/";
    $url .= $self->{config}->{shortcuts}
        ->relatif( $self->{config}->get("texsrc") );
    $self->{data}->{url} = $url;
}

sub DESTROY {
    my $self = shift;
    if ( $self->{project}->{'nom'} ) {

        $self->{config}->close_project();

    } else {
        $self->{config}->save();
    }
    return (1);
}

sub to_content {
    my $self    = shift;
    my $content = '';
    my $type    = 'text/plain';
    if (   ( ( scalar  @{ $self->{errors} } ) == 0 )
        && ( ( keys %{ $self->{data} } ) == 0 ) )
    {
        $content = join( "\n", @{ $self->{messages} } );

    }
    else {
        $type = 'application/json';
        $self->{status} = 500 if ( ( scalar @{ $self->{errors} } ) > 0 );
        $content = encode_json(
            {   status  => $self->{status},
                message => join( "\n", @{ $self->{messages} } ),
                errors  => @{ $self->{errors} },
                data    => $self->{data}
            }
        );
    }
    return ( $self->{status}, $type, length($content), $content );
}
sub redirect {
    my $self    = shift;

    return (0) if (!defined $self->{url_return});
    my $uri = URI->new( $self->{url_return} );
    my $action = $self->{action};
    $action =~s/\//_/g;
    $uri->query_form(action =>$action, status =>$self->{status}, message=>join( "\n", @{ $self->{messages} }));
    
    return $uri->as_string;
}

sub status {
    my $self = shift;
    return $self->{status};
}

sub get_config {
    my ( $self, $key ) = @_;
    return $self->{config}->get($key);
}

sub sheet_delete {
    my $self = shift;
    $self->clear_processing('capture:');
}

sub get_api_url {
    my ($dir)    = @_;
    my $config = AMC::Config->new(
        shortcuts => AMC::Path::new( home_dir => $dir ),
        home_dir  => $dir,
        o_dir     => $dir
    );
    return $config->get('api_url');
}

sub set_config {
    my ( $self, $key, $value ) = @_;
    $self->{config}->set( 'project:' . $key, $value );
}

sub get_shortcut {
    my ( $self, $shortcut ) = @_;
    return ( $self->{config}->{shortcuts}->absolu($shortcut) );
}

sub get_relatif {
    my ( $self, $shortcut ) = @_;
    return ( $self->{config}->{shortcuts}->relatif($shortcut) );
}

sub call {
    my ( $self, $action ) = @_;
    my $base_url = $self->{config}->get('global:api_url');
    $action =~ /^\Q$base_url\E(.*)$/;
    $self->{action} =$1;
    my $method = $ROUTING{$self->{action}};
    if ( $self->can($method) ) {
        $self->$method;
    }
    else {
        $self->{status} = 400;
        push( @{ $self->{messages} }, "Bad Request" );
    }

}
