package PVE::Storage::TestCopyOffloadNaming;

use strict;
use warnings;

use lib qw(..);

use PVE::Storage;
use PVE::Storage::Plugin;
use Test::More;

# The names copy_image_start() parks its placeholder under must satisfy TWO opposing
# properties at once, and getting either one wrong is a silent, expensive bug:
#
#   1. INVISIBLE to the volume lister. If the lister accepts the name, the placeholder
#      shows up as a real disk of that VM -- a phantom the GUI offers to attach, and a
#      permanent one if the copy dies mid-flight.
#   2. STILL RESERVING the disk NUMBER. The caller drops the storage lock between
#      prepare() and start(), so if the parked name stops reserving, a concurrent
#      allocation can take it -- and the failing copy's rollback then frees somebody
#      else's volume. That is silent third-party data loss.
#
# The two properties come from two different regexes, which is why a name can satisfy
# one and not the other:
#
#   - listers are ANCHORED   (rbd_ls: m/^(?:vm|base)-(\d+)-/,
#                             LvmThin list_images: m/^(vm|base)-(\d+)-/)
#   - $get_vm_disk_number is UNANCHORED (Plugin.pm)
#
# So a PREFIX is invisible but still reserves, and a SUFFIX is the exact opposite on
# both counts. This test pins that, because nothing about the naming looks load-bearing
# at a glance and a well-meaning rename to 'vm-101-disk-0.copytmp' would reintroduce
# both bugs at once without failing anything else.

# The anchored patterns the listers actually use, kept here so a change to either one
# is caught rather than silently narrowing what these names protect.
my $rbd_lister_re = qr/^(?:vm|base)-(\d+)-/;
my $lvmthin_lister_re = qr/^(vm|base)-(\d+)-/;

my $tests = [
    # [ name, listed?, reserves a disk number? ]
    ['vm-101-disk-0', 1, 1], # the real volume: listed and reserving
    ['copytmp-vm-101-disk-0', 0, 1], # parked placeholder
    ['copynew-vm-101-disk-0', 0, 1], # staging clone
    ['vm-101-disk-0.copytmp', 1, 1], # the SUFFIX form: listed => phantom. Do not use.
];

plan tests => scalar($tests->@*) * 3 + 2;

for my $t ($tests->@*) {
    my ($name, $listed, $reserves) = $t->@*;

    is(!!($name =~ $rbd_lister_re), !!$listed, "rbd lister: '$name' listed = " . ($listed ? 1 : 0));
    is(
        !!($name =~ $lvmthin_lister_re), !!$listed,
        "lvmthin lister: '$name' listed = " . ($listed ? 1 : 0),
    );

    # Unanchored on purpose -- this is the reservation half.
    is(
        !!($name =~ qr/(vm|base)-101-disk-(\d+)/), !!$reserves,
        "'$name' reserves a disk number = " . ($reserves ? 1 : 0),
    );
}

# The property that actually matters, through the real allocator rather than a regex:
# with ONLY the parked placeholder present, disk 0 must not be handed out again.
my $scfg = { type => 'rbd' };
is(
    PVE::Storage::Plugin::get_next_vm_diskname(['vm-101-disk-0'], 'st', 101, undef, $scfg),
    'vm-101-disk-1',
    'the real volume reserves its disk number',
);
is(
    PVE::Storage::Plugin::get_next_vm_diskname(
        ['copytmp-vm-101-disk-0'], 'st', 101, undef, $scfg,
    ),
    'vm-101-disk-1',
    'a parked placeholder ALONE still reserves the disk number',
);

done_testing();
