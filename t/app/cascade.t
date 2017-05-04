#!/usr/bin/env perl6
use v6;

use HTTP::Request::Common;
use Smack::App::Cascade;
use Smack::App::File;
use Smack::Test;
use Test;

subtest {
    my $cascade = Smack::App::Cascade.new;

    test-p6wapi $cascade, -> $c {
        my $res = $c.request(GET '/');
        is $res.code, 404, 'no apps get a 404';
    };

    push $cascade.apps, Smack::App::File.new(root => 't/middleware'.IO).to-app;
    push $cascade.apps, Smack::App::File.new(root => 't/util'.IO).to-app;
    push $cascade.apps, -> %env {
        start { 404, [], [ 'Custom 404 Page' ] }
    };

    test-p6wapi $cascade, -> $c {
        my $res = $c.request(GET '/access_log.t');
        is $res.code, 200, 'found access_log.t';

        $res = $c.request(GET '/foo');
        is $res.code, 404, 'no finding foo';
        is $res.decoded-content, 'Custom 404 Page', 'custom app fallback';

        $res = $c.request(GET '/foreach.t');
        is $res.code, 200, 'found foreach.t';
    };
}

done-testing;