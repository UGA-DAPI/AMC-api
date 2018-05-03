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
    my ( $status, $headers, $content ) = $api->to_file();
    my $response = $request->new_response();
    if (my $url = $api->redirect())
    {
        $response->redirect($url);
    } else {
        $response->status($status);
        $response->headers($headers);
        $response->content($content);
    }

    $api = undef;
    return $response->finalize;
};

my $download = sub {
    my $env = shift;
    my $request = Plack::Request->new($env);
    my $api  = AMC::Api->new( $dir, $request);
    my ( $status, $headers, $content ) = $api->to_file($request->path_info);
     my $response = $request->new_response();
    if (my $url = $api->redirect())
    {
        $response->redirect($url);
    } else {
        $response->status($status);
        $response->headers($headers);
        $response->content($content);
    }

    $api = undef;
    return $response->finalize;
};

my $process = sub {
    my $env     = shift;
    my $request = Plack::Request->new($env);
    my $api     = AMC::Api->new( $dir, $request);

    $api->call( $request->path_info ) if ( $api->status() != 403 );

    my ( $status, $headers, $content ) = $api->to_content;
    my $response = $request->new_response();
    if (my $url = $api->redirect())
    {
        $response->redirect($url);
    } else {
        $response->status($status);
        $response->headers($headers);
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

