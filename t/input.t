#!perl6

use v6;

use Test;
use Smack::Test::Smackup;

my @tests =
    -> $c, $url {
        use HTTP::Request;
        my $req = HTTP::Request.new(POST => $url);
        $req.header.field(Content-Type => 'text/plain');
        $req.add-content('this is a test');
        my $response = $c.request($req);

        ok $response.is-success, 'request is ok';
        ok $response.content, 'this is a test';
    },
    ;

my $test-server = Smack::Test::Smackup.new(:app<echo.p6w>, :@tests);
$test-server.run;

done-testing;