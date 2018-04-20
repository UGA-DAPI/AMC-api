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

use POSIX qw/strftime/;
use Cwd;
use File::Spec::Functions
    qw/splitpath catpath splitdir catdir catfile rel2abs tmpdir/;

use Encode;
use Unicode::Normalize;
use I18N::Langinfo qw(langinfo CODESET);
use Locale::Language;

use Api;

use AMC::Basic;

use utf8;

use_gettext;
use_amc_plugins();

POSIX::setlocale( &POSIX::LC_NUMERIC, "C" );

my $debug           = 0;
my $debug_file      = '';
my $show_secret     = 0;
my $generate_secret = 0;
my $home_dir        = cwd;
my $api_url         = '/';

my $api = Api->new($home_dir);

sub promptUser {

    my ( $promptString, $defaultValue ) = @_;

    if ($defaultValue) {
        print $promptString, "[", $defaultValue, "]: ";
    }
    else {
        print $promptString, ": ";
    }

    $| = 1;          # force a flush after our print
    $_ = <STDIN>;    # get the input from STDIN (presumably the keyboard)

    chomp;

    if ("$defaultValue") {
        return $_ ? $_ : $defaultValue;    # return $_ if it has a value
    }
    else {
        return $_;
    }
}

GetOptions(
    "show-secret!"     => \$show_secret,
    "generate-secret!" => \$generate_secret,
);

# Gets system encoding
my $encodage_systeme = langinfo( CODESET() );

my $secret = $o{'api_secret'};
if ($generate_secret) {
    $secret = join( '', map( sprintf( q|%X|, rand(16) ), 1 .. 32 ) );
    $api->{config}->set( 'general:api_secret', $secret );
}
if ($show_secret) {
    print( "secret :", $secret );
}
else {
    $api_url = $o{'api_url'} if ( defined $o{'api_url'} );
    $api_url = promptUser( "Api url:", $api_url );
    $api->{config}->set( 'general:api_url', $api_url );
    if ($generate_secret) {
        print( "Secret :", $secret );
    }

}
$api->{config}->save();

