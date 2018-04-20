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
use JSON;

use Api;

my $home_dir = cwd;
my $o_file   = '';

my %o = ();

$o_file = $home_dir . "/cf.default.xml";

# Read general options ...

if ( -r $o_file ) {
    %o = Api::pref_xx_lit($o_file);
}

my $base_url = $o{'api_url'};

my $static = sub {
    my $request = Plack::Request->new(shift);
    my $json;
    my $post   = $request->body_parameters->as_hashref;
    my $data   = $post;
    my @errors = ();
    $data->{ip}          = $request->address;
    $data->{remote_host} = $request->remote_host;
    $data->{referer}     = $request->referer;
    $json                = {
        status  => 200,
        message => 'success',
        errors  => \@errors,
        data    => $data
    };

    my $response = $request->new_response(200);
    $response->content_type('application/json');
    $response->content( encode_json($json) );

    return $response->finalize;
};

my %ROUTING = (
    '/'     => \&serve_root,
    '/echo' => \&serve_echo,
);

my $app = sub {
    my $request = Plack::Request->new(shift);
    my $json;
    my $post   = $request->body_parameters->as_hashref;
    my $data   = $post;
    my @errors = ();
    $data->{ip}          = $request->address;
    $data->{remote_host} = $request->remote_host;
    $data->{referer}     = $request->referer;
    $json                = {
        status  => 200,
        message => 'success',
        errors  => \@errors,
        data    => $data
    };

    my $response = $request->new_response(200);
    $response->content_type('application/json');
    $response->content( encode_json($json) );

    return $response->finalize;
};
my $mw = sub {
    my $app = shift;
    sub {
        my $env = shift;
        $app->($env);
    };

    my $request = Plack::Request->new($env);
    my $json;
    my $post   = $request->body_parameters->as_hashref;
    my @errors = ();
    if ( !defined $post->{apikey} ) {
        @errors = ("No apikey");
    }
    else {
        my $project_dir
            = $o{'rep_projets'} . $request->address . "/" . $post->{apikey};
        if (   ( ( !-d $project_dir ) && ( !defined $post->{globalkey} ) )
            || ( $post->{globalkey} != $o{'api_secret'} ) )
        {
            @errors = ("Bad apikey");
        }
    }

    if ( $#errors == 0 ) {
        my $route = $ROUTING{ $request->path_info };
        if ($route) {
            return $route->($env);
        }

        $data->{ip}          = $request->address;
        $data->{remote_host} = $request->remote_host;
        $data->{referer}     = $request->referer;
        $json                = {
            status  => 200,
            message => 'success',
            errors  => \@errors,
            data    => $data
        };
    }
    if ($#errors) {
        $json = {
            status  => 400,
            message => 'error',
            errors  => \@errors
        } my $response = $request->new_response(400);
        $response->content_type('application/json');
        $response->content( encode_json($json) );
    }
    else {

    }
    my $response = $request->new_response(200);
    $response->content_type('application/json');
    $response->content( encode_json($json) );

    return $response->finalize;
};

builder {
    mount $base_url. "/quiz"        => $app;
    mount $base_url. "/document"    => $app;
    mount $base_url. "/sheet"       => $app;
    mount $base_url. "/association" => $app;
    mount $base_url. "/grading"     => $app;
    mount $base_url. "/annotation"  => $app;
    mount $base_url. "/file"        => $app;
    mount $base_url. "/image"       => $app;
    mount $base_url. "/"            => $img;
}

