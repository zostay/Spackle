unit class HTTP::Server::Smack;

use URI::Encode;
use DateTime::Format::RFC2822;
use HTTP::Headers;
use HTTP::Request::Supply;
use HTTP::Status;

has Str $.host;
has Int $.port;

has Bool $.debug = False;

has $!listener;

my sub _errors {
    my $errors = Supplier.new;
    $errors.Supply.tap: -> $s { $*ERR.say($s) };
    $errors;
}

has %!global =
    'p6w.version'          => v0.7.Draft,
    'p6w.errors'           => _errors,
    'p6w.run-once'         => False,
    'p6w.multithread'      => False,
    'p6w.multiprocess'     => False,
    'p6w.protocol.support' => set('request-response'),
    'p6w.protocol.enabled' => set('request-response'),
    ;

method run(&app is copy) {
    &app = app(%!global) if &app.returns ~~ Callable;
    self.setup-listener;
    self.accept-loop(&app);
}

method setup-listener {
    $!listener = IO::Socket::Async.listen($!host, $!port);
}

method accept-loop(&app) {
    react {
        whenever $!listener -> $conn {

            my Promise $header-done-promise .= new;
            my $header-done = $header-done-promise.vow;

            my Promise $body-done-promise .= new;
            my $body-done = $body-done-promise.vow;

            my Promise $ready-promise .= new;
            my $ready = $ready-promise.vow;

            my %env =
                SERVER_PORT           => $!port,
                SERVER_NAME           => $!host,
                SCRIPT_NAME           => '',
                #REMOTE_ADDR           => $conn.localhost,
                'p6w.url-scheme'      => 'http',
                'p6w.body.encoding'   => 'UTF-8',
                'p6w.ready'           => $ready-promise,
                'p6w.protocol'        => 'http',
                'p6wx.header.done'    => $header-done-promise,
                'p6wx.body.done'      => $body-done-promise,
                ;

            for %!global.keys -> $key {
                next if %env{ $key }:exists;
                %env{ $key } := %!global{ $key };
            }

            #$*SCHEDULER.cue: {
                self.handle-connection(&app, :%env, :$conn, :$ready, :$header-done, :$body-done);
            #};
        }
    }
}

constant CR = 0x0d;
constant LF = 0x0a;

method !temp-file {
    ($*TMPDIR ~ '/' ~ $*USER ~ '.' ~ ([~] ('A' .. 'Z').roll(8)) ~ '.' ~ $*PID).IO
}

method handle-connection(&app, :%env, :$conn, :$ready, :$header-done, :$body-done) {
    my $res = (400, [ 'Content-Type' => 'text/plain' ], [ 'Bad Request' ]);

    note "[debug] Received connection..." if $!debug;

    my $header-end;
    my $checked-through = 3;
    my $whole-buf = Buf.new;

    whenever HTTP::Request::Supply.parse-http($conn.Supply(:bin), :debug) -> %request {

        # We start a threaad here because we need to wait for the response.
        # If we do that in the same thread as parse-http(), parse-http()
        # may never get a chance to resume: DEADLOCK.
        #
        # TODO Figure out why this is necessary and if there is a better way.
        start {
            %env = |%env, |%request;

            my $uri = %env<REQUEST_URI>;
            my (Str $path, Str $query-string) = $uri.split('?', 2);
            %env<PATH_INFO>        = uri_decode($path);
            %env<QUERY_STRING>     = $query-string // '';
            %env<CONTENT_LENGTH> //= Int;
            %env<CONTENT_TYPE>   //= Str;

            note "[debug] QUERY_STRING = $query-string.perl()";

            $res = app(%env);

            # We stop here until the response is done beofre handling another request
            await self.handle-response($res, :$conn, :%env, :$ready, :$header-done, :$body-done);
        }
    }
}

method send-header($status, @headers, $conn) returns Str {
    my $status-msg = get_http_status_msg($status);

    # Write headers in ISO-8859-1 encoding
    $conn.write("HTTP/1.1 $status $status-msg\x0d\x0a".encode('ISO-8859-1'));
    $conn.write("{.key}: {.value}\x0d\x0a".encode('ISO-8859-1')) for @headers;
    $conn.write("\x0d\x0a".encode('ISO-8859-1'));

    # Detect encoding
    my $ct = @headers.first(*.key.fc eq 'content-type'.fc);
    my $charset = $ct.value.comb(/<-[;]>/)».trim.first(*.starts-with("charset="));
    $charset.=substr(8) if $charset;
    $charset//Str
}

method handle-response(Promise() $promise, :$conn, :%env, :$ready, :$header-done, :$body-done) {
    $promise.then({
        my (Int() $status, List() $headers, Supply() $body) := $promise.result;
        self.handle-inner($status, $headers, $body, $conn, :$ready, :$header-done, :$body-done, :%env);

        # consume and discard the bytes in the iput stream, just in case the app
        # didn't read from it.
        %env<p6w.input>.tap if %env<p6w.input> ~~ Supply:D;

        # keep the promise the same
        $promise.result;
    });
}

method handle-inner(Int $status, @headers, Supply $body, $conn, :$ready, :$header-done, :$body-done, :%env) {
    my $charset = self.send-header($status, @headers, $conn) // %env<p6w.body.encoding>;
    $header-done andthen $header-done.keep(True);

    react {
        whenever $body -> $v {
            my Blob $buf = do given ($v) {
                when Blob { $v }
                default   { $v.Str.encode($charset) }
            };
            $conn.write($buf) if $buf;

            LAST {
                my $ct = @headers.first(*.key.fc eq 'content-type'.fc);
                my $cl = @headers.first(*.key.fc eq 'content-length'.fc);
                my $te = @headers.first(*.key.fc eq 'transfer-encoding'.fc);

                # Close the connection if requested by the client
                if %env<HTTP_CONNECTION>.fc eq 'close'.fc {
                    $conn.close;
                }

                # Close the connection if the app did not provide content
                # length via:
                #   - Content-Length: N
                #   - Transfer-Encoding: chunked
                #   - Content-Type: multipart/byteranges
                elsif !defined($cl)
                        && (!defined($te) || $te.value.fc ne 'chunked'.fc)
                        && (!defined($ct) || $ct.value !~~ m:i{ ^ "multipart/byteranges" >> }) {
                    $conn.close;
                }

                $body-done andthen $body-done.keep(True);
            }

            QUIT {
                my $x = $_;
                $conn.close;
                CATCH {
                    # this is stupid, IO::Socket needs better exceptions
                    when "Not connected!" {
                        # ignore it
                    }
                }
                $body-done andthen $body-done.break($x);
            }
        }

        $ready andthen $ready.keep(True);
    }
}
