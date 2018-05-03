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

use Cwd;

use Plack::Request;
use Plack::Builder;
use Plack::App::File;

use AMC::Api;

my $dir    = cwd;
my $config = AMC::Api::get_api_url($dir);
my $img = sub {
    my $env = shift;
    my $request = Plack::Request->new($env);
    my $api     = AMC::Api->new( $dir, $request );
    my $file    = $api->get_file();
    $api = undef;
    return Plack::App::File->new( $file )->to_app($env);
};

my $download = sub {
    my $env = shift;
    my $request = Plack::Request->new($env);
    my $api  = AMC::Api->new( $dir, $request);
    #my $file = $api->get_file( $request->path_info );
    my $root = $api->get_root();
    $api = undef;
    return Plack::App::File->new( root => $root )->to_app($env);
};

my $process = sub {
    my $env     = shift;
    my $request = Plack::Request->new($env);
    my $api     = AMC::Api->new( $dir, $request);

    $api->call( $request->path_info ) if ( $api->status() != 403 );

    my ( $status, $type, $length, $content ) = $api->to_content;
    my $response = $request->new_response();
    if (my $url = $api->redirect())
    {
        $response->redirect($url);
    } else {
        $response->status($status);
        $response->content_type($type);
        $response->content_length($length);
        $response->content($content);
    }

    $api = undef;
    return $response->finalize;
};

builder {
    mount $config. "/image"    => $img;
    mount $config. "/download" => $download;
    mount $config. "/"         => $process;
}

