use strict;
use warnings;
use Test::More tests => 28;
use FindBin;
use lib "$FindBin::Bin/lib";
use Gearman::Driver::Test;
use File::Slurp;
use File::Temp qw(tempfile);

BEGIN {
    $ENV{GEARMAN_DRIVER_ADAPTOR} = 'Gearman::Driver::Adaptor::PP';
}

my $test = Gearman::Driver::Test->new();

$test->run_gearmand;
$test->run_gearman_driver;

my $telnet = $test->telnet_client;
my $gc     = $test->gearman_client;

# give gearmand + driver at least 5 seconds to settle
foreach my $namespace (qw(Gearman::Driver::Test::Live::NS1::Basic)) {
    for ( 1 .. 5 ) {
        my $pong = $gc->do_task( "${namespace}::ping" => 'ping' );
        sleep(1) && next unless $pong;
        is( $$pong, 'pong', "Job '${namespace}::ping' returned correct value" );
        last;
    }
}

{
    my $pong = $gc->do_task( 'something_custom_ping' => 'ping' );
    is( $$pong, 'p0nG', 'Job "something_custom_ping" returned correct value' );
}

{
    my $pong = $gc->do_task( 'Gearman::Driver::Test::Live::NS2::Ping2::ping' => 'ping' );
    is( $$pong, 'PONG', 'Job "Gearman::Driver::Test::Live::NS2::Ping2::ping" returned correct value' );
}

# i hope this assumption is always true:
# out of 1000 jobs all 4 processes handled at least one job
{
    foreach my $namespace (qw(Gearman::Driver::Test::Live::NS1::Basic)) {
        my %pids = ();
        for ( 1 .. 1000 ) {
            my $pid = $gc->do_task( "${namespace}::four_processes" => '' );
            next unless $pid;
            $pids{$$pid}++;
            last if scalar( keys(%pids) ) == 10;
        }
        is( scalar( keys(%pids) ), 10, "10 different processes handled job '${namespace}::four_processes'" );
    }
}

# Let's change min/max processes via console
{
    $telnet->print('set_min_processes Gearman::Driver::Test::Live::NS1::Basic::four_processes 2');
    $telnet->print('set_max_processes Gearman::Driver::Test::Live::NS1::Basic::four_processes 2');
    my %pids = ();
    for ( 1 .. 1000 ) {
        my $pid = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::four_processes' => '' );
        next unless $pid;
        $pids{$$pid}++;
        last if scalar( keys(%pids) ) == 2;
    }
    is( scalar( keys(%pids) ), 2, "2 different processes handled job 'four_processes'" );
    $telnet->print('set_min_processes Gearman::Driver::Test::Live::NS1::Basic::four_processes 4');
    $telnet->print('set_max_processes Gearman::Driver::Test::Live::NS1::Basic::four_processes 4');
}

{
    my $pid1 = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::pid1' => '' );
    my $pid2 = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::pid2' => '' );
    is( $$pid1, $$pid2, 'Got some pid for different jobs of same ProcessGroup' );
}

{
    my $first_pid = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::get_pid' => '' );
    like( $$first_pid, qr~^\d+$~, 'Job "get_pid" returned correct value' );

    # test max_idle_time (5)
    for ( 1 .. 3 ) {
        my $pid = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::get_pid' => '' );
        is( $$first_pid, $$pid, 'Still the same PID' );
        sleep(2);
    }

    sleep(6);
    my $pid = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::get_pid' => '' );
    isnt( $$first_pid, $$pid, 'Got another PID' );

    # The worker really killed after it has been idle. Famous last words!
    $first_pid = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::sleepy_pid' => '10' );
    like( $$first_pid, qr/^\d+$/, 'Got PID' );
    isnt( $$first_pid, $$pid, 'Got another PID' );
}

{
    my $filename = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::BeginEnd::job' => 'some workload ...' );
    my $text = read_file($$filename);
    is(
        $text,
        "begin some workload ...\njob some workload ...\nend some workload ...\n",
        'Begin/end blocks in worker have been run'
    );
    unlink $$filename;
}

{
    my $string = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Spread::main' => 'some workload ...' );
    is( $$string, '12345', 'Spreading works (tests $worker->server attribute)' );
}

{
    my $string = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::EncodeDecode::job3' => 'some workload ...' );
    is( $$string, 'STANDARDENCODE::some workload ...::STANDARDENCODE', 'Standard encoding works' );
}

{
    my $string = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::EncodeDecode::job4' => 'some workload ...' );
    is( $$string, 'CUSTOMENCODE::some workload ...::CUSTOMENCODE', 'Custom encoding works' );
}

{
    my $string = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::EncodeDecode::job1' => 'some workload ...' );
    is( $$string, 'STANDARDDECODE::some workload ...::STANDARDDECODE', 'Standard decoding works' );
}

{
    my ( $fh, $filename ) = tempfile( CLEANUP => 1 );
    $gc->dispatch_background( 'Gearman::Driver::Test::Live::NS2::BeginEnd::job' => $filename );
    sleep(2);
    my $text = read_file($filename);
    is( $text, "begin ...\nend ...\n", 'Begin/end blocks in worker have been run, even if the job dies' );
    unlink $filename;
}

{
    my $string = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::EncodeDecode::job2' => 'some workload ...' );
    is( $$string, 'CUSTOMDECODE::some workload ...::CUSTOMDECODE', 'Custom decoding works' );
}

{
    my ( $fh, $filename ) = tempfile( CLEANUP => 1 );
    $gc->do_task( 'Gearman::Driver::Test::Live::NS2::UseBase::job' => $filename );
    my $text = read_file($filename);
    is( $text, "begin ...\njob ...\nend ...\n", 'Begin/end blocks in worker base class have been run' );
    unlink $filename;
}

{
    $gc->dispatch_background( 'Gearman::Driver::Test::Live::NS1::Basic::quit' => 'exit' );
    sleep(3);    # wait for the worker being restarted
    my $string = $gc->do_task( 'Gearman::Driver::Test::Live::NS1::Basic::quit' => 'foo' );
    is( $$string, 'i am back', 'Worker process restarted after exit' );
}

{
    foreach my $namespace (
        qw(
        Gearman::Driver::Test::Live::NS1::DefaultAttributes
        Gearman::Driver::Test::Live::NS1::OverrideAttributes
        )
      )
    {
        my $string = $gc->do_task( "${namespace}::job" => 'workload' );
        is(
            $$string,
            "${namespace}::ENCODE::${namespace}::DECODE::workload::DECODE::${namespace}::ENCODE::${namespace}",
            'Encode/decode override attributes'
        );
    }
}

{
    my $string = $gc->do_task( 'Gearman::Driver::Test::Live::job' => 'some workload ...' );
    is( $$string, 'ok', 'loaded root namespace' );
}

#
#
# AddJob
#
#

foreach my $namespace (qw(Gearman::Driver::Test::Live::NS3::AddJob)) {
    {
        my $string = $gc->do_task( "${namespace}::job1" => 'foo' );
        is( $$string, 'CUSTOMENCODE::foo::CUSTOMENCODE', 'Custom encoding works' );
    }

    {
        my $filename = $gc->do_task( "${namespace}::begin_end" => 'some workload ...' );
        my $text = read_file($$filename);
        is(
            $text,
            "begin some workload ...\njob some workload ...\nend some workload ...\n",
            'Begin/end blocks in worker have been run'
        );
        unlink $$filename;
    }

    # i hope this assumption is always true:
    # out of 1000 jobs all 4 processes handled at least one job
    {
        my %pids = ();
        for ( 1 .. 1000 ) {
            my $pid = $gc->do_task( "${namespace}::four_processes" => 'xxx' );
            next unless $pid;
            $pids{$$pid}++;
            last if scalar( keys(%pids) ) == 4;
        }
        is( scalar( keys(%pids) ), 4, "4 different processes handled job '${namespace}::four_processes'" );
    }
}

$telnet->print('shutdown');
