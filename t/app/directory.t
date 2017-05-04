#!/usr/bin/env perl6
use v6;

use HTTP::Request::Common;
use Smack::App::Directory;
use Smack::Test;
use Test;

my $handler = Smack::App::Directory.new(root => 'share'.IO);

test-p6wapi $handler, -> $c {
    my $res = $c.request(GET '/');
    is $res.code, 200, 'getting #foo is 200';
    like $res.decoded-content, rx{"/%23foo"}, 'found #foo';

    $res = $c.request(GET '/..');
    is $res.code, 403, 'getting root parent is 403';

    $res = $c.request(GET '/..%00foo');
    is $res.code, 400, 'encoding trickery is 400';

    $res = $c.request(GET '/..%5cfoo');
    is $res.code, 403, 'getting foo of root parent is 403 even with encoding trickery';

    $res = $c.request(GET '/');
    is $res.code, 200, 'getting index is 200';
    like $res.decoded-content, rx{"Index of /"}, 'indexing is indexing';

    try {
        mkdir "share/stuff..";
        LEAVE rmdir "share/stuff..";

        spurt "share/stuff../Hello.txt", "Hello\n";
        LEAVE unlink "share/stuff../Hello.txt";

        $res = $c.request(GET '/stuff../Hello.txt');
        is $res.code, 200, 'able to get to Hello.txt';
        is $res.decoded-content, "Hello\n", 'file contains expected content';
    }
};

done-testing;