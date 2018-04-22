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

use Api;

my $dir = cwd;

my $img = sub {
    my $request = Plack::Request->new(shift);
    my $api = Api->new( $dir, $request->address, $request->path_info );
    Plack::App::File->new( file => $api->get_file() )->to_app;
};

my $download = sub {
    my $request = Plack::Request->new(shift);
    my $path    = $request->path_info;
    my $post    = $request->body_parameters->as_hashref;
    my $api     = Api->new( $dir, $request->address, $post, $request->uploads );

    Plack::App::File->new( file => $api->get_file( $request->path_info ) )
        ->to_app;
};

my $process = sub {
    my $env     = shift;
    my $request = Plack::Request->new($env);
    my $path    = $request->path_info;
    my $post    = $request->body_parameters->as_hashref;
    my $api     = Api->new( $dir, $request->address, $post );

    $api->call( $request->path_info ) if ( $api->status() != 403 );

    my ($status, $type, $lenght, $content) = $api->to_content;
    my $response = $request->new_response( $status );
    $response->content_type($type);
    $response->content_length($length);
    $response->content( $content );

    return $response->finalize;
};

builder {
    mount $base_url. "/image"    => $img;
    mount $base_url. "/download" => $download;
    mount $base_url. "/"         => $process;
}

