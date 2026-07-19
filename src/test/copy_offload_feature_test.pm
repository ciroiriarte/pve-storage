package PVE::Storage::TestCopyOffloadFeature;

use strict;
use warnings;

use lib qw(..);

# PVE::Storage first: it registers the plugins in an order that resolves the
# DirPlugin <-> Storage.pm circular load. Requiring BTRFSPlugin on its own fails.
use PVE::Storage;
use PVE::Storage::BTRFSPlugin;
use PVE::Storage::LvmThinPlugin;
use Test::More;

# Which volumes a plugin advertises 'copy-offload-atomic' for. This is the gate the
# whole path hangs off: advertising a volume the plugin cannot actually copy sends the
# clone into copy_image_prepare() only to die there, and NOT advertising one it can
# copy silently falls back to a full host-side byte copy. Neither failure is visible
# from a passing clone, so the answers are pinned here.

my $btrfs_scfg = { path => '/some/btrfs', type => 'btrfs' };
my $lvmthin_scfg = { vgname => 'vg0', thinpool => 'tp', type => 'lvmthin' };

my $tests = [
    # [ description, class, scfg, volname, snapname, expected ]

    # btrfs stores raw and subvol as subvolumes, which is what it can snapshot.
    [
        'btrfs raw is advertised',
        'PVE::Storage::BTRFSPlugin', $btrfs_scfg, '100/vm-100-disk-0.raw', undef, 1,
    ],
    [
        'btrfs subvol is advertised',
        'PVE::Storage::BTRFSPlugin', $btrfs_scfg, '100/subvol-100-disk-0.subvol', undef, 1,
    ],
    [
        'btrfs raw is advertised from a snapshot too',
        'PVE::Storage::BTRFSPlugin', $btrfs_scfg, '100/vm-100-disk-0.raw', 'snap1', 1,
    ],
    # qcow2 and vmdk are plain files here, not subvolumes, so the subvolume-snapshot
    # path does not apply to them.
    [
        'btrfs qcow2 is NOT advertised',
        'PVE::Storage::BTRFSPlugin', $btrfs_scfg, '100/vm-100-disk-0.qcow2', undef, undef,
    ],
    [
        'btrfs vmdk is NOT advertised',
        'PVE::Storage::BTRFSPlugin', $btrfs_scfg, '100/vm-100-disk-0.vmdk', undef, undef,
    ],

    # lvmthin is raw-only, and a thin snapshot does not pin its origin, so every key
    # qualifies.
    [
        'lvmthin current is advertised',
        'PVE::Storage::LvmThinPlugin', $lvmthin_scfg, 'vm-100-disk-0', undef, 1,
    ],
    [
        'lvmthin base is advertised',
        'PVE::Storage::LvmThinPlugin', $lvmthin_scfg, 'base-100-disk-0', undef, 1,
    ],
    [
        'lvmthin snapshot is advertised',
        'PVE::Storage::LvmThinPlugin', $lvmthin_scfg, 'vm-100-disk-0', 'snap1', 1,
    ],
];

plan tests => scalar($tests->@*) + 2;

for my $t ($tests->@*) {
    my ($desc, $class, $scfg, $volname, $snapname, $expected) = $t->@*;

    my $got = $class->volume_has_feature(
        $scfg, 'copy-offload-atomic', 'store', $volname, $snapname, 0,
    );

    if (defined($expected)) {
        is($got, $expected, $desc);
    } else {
        ok(!$got, $desc);
    }
}

# An unrelated feature must still come back from the normal table rather than being
# swallowed by the copy-offload handling.
ok(
    PVE::Storage::BTRFSPlugin->volume_has_feature(
        $btrfs_scfg, 'snapshot', 'store', '100/vm-100-disk-0.raw', undef, 0,
    ),
    'btrfs still answers for unrelated features',
);
ok(
    PVE::Storage::LvmThinPlugin->volume_has_feature(
        $lvmthin_scfg, 'snapshot', 'store', 'vm-100-disk-0', undef, 0,
    ),
    'lvmthin still answers for unrelated features',
);

done_testing();
