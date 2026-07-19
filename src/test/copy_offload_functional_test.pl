#!/usr/bin/perl

# Functional tests for the copy-offload hooks of BTRFSPlugin and LvmThinPlugin.
#
# Unlike the rest of src/test, this one touches real storage: it builds a loop-backed
# btrfs filesystem and a loop-backed LVM thin pool, drives copy_image_prepare/start/
# status against them, and checks the resulting images byte for byte. That needs root
# and the btrfs/lvm tools, so it is NOT part of run_plugin_tests.pl -- run it by hand:
#
#     perl copy_offload_functional_test.pl
#
# It skips cleanly rather than failing when it cannot run. Everything it creates lives
# under /tmp and on its own loop devices, and is torn down at exit even on failure; it
# never touches an existing volume group or mount.
#
# What is actually being checked, and why these and not others:
#
#  - a copy taken from a SNAPSHOT returns the snapshot's content, not the live volume's.
#    Getting this wrong is silent: the clone is readable and passes every check, it just
#    holds the wrong data.
#  - the copy survives deleting the source outright. That is what 'copy-offload-atomic'
#    promises and what separates these backends from a ZFS clone.
#  - two prepares for the SAME target VM return different names. The core prepares every
#    disk of a VM before starting any of them, so a reservation its own lister cannot see
#    makes every multi-disk clone fail.

use strict;
use warnings;

use lib qw(..);

use File::Path qw(mkpath rmtree);
use PVE::Storage;
use PVE::Storage::BTRFSPlugin;
use PVE::Storage::LvmThinPlugin;
use PVE::Tools qw(run_command);
use Test::More;

my $BTRFS_MNT = '/tmp/pve-copyoffload-btrfs';
my $BTRFS_IMG = '/tmp/pve-copyoffload-btrfs.img';
my $LVM_IMG = '/tmp/pve-copyoffload-lvm.img';
my $VG = 'pvecopyoffloadtest';

my @cleanup;

sub sh { return scalar(qx{$_[0] 2>/dev/null}) }

sub cleanup_all {
    for my $c (reverse @cleanup) { eval { $c->() }; }
    @cleanup = ();
}
END { cleanup_all() }
$SIG{INT} = $SIG{TERM} = sub { cleanup_all(); exit 1 };

if ($> != 0) {
    plan skip_all => 'needs root to create loop devices, filesystems and volume groups';
}
for my $tool (qw(btrfs mkfs.btrfs losetup findmnt lvcreate vgcreate pvcreate)) {
    if (!sh("command -v $tool")) {
        plan skip_all => "missing required tool '$tool'";
    }
}
if (sh("vgs --noheadings -o vg_name 2>/dev/null") =~ /\b\Q$VG\E\b/) {
    plan skip_all => "volume group '$VG' already exists - refusing to touch it";
}

plan tests => 21;

# Hash the WHOLE object, and let md5sum do its own reading.
#
# Deliberately not 'dd bs=1M count=N | md5sum': dd counts a short read as a full block,
# so it can return less than asked for, and how much depends on whether the data came
# from the page cache or off the disk. Comparing a freshly written source against a
# cold copy that way reports a mismatch between two byte-identical files. It also hides
# a missing file as the md5 of empty input.
sub md5_of {
    my ($path) = @_;

    die "cannot hash '$path': not present\n" if !-e $path;
    my $out = sh("md5sum '$path'");
    $out =~ s/\s.*//s;
    die "md5sum of '$path' produced nothing\n" if $out !~ /^[0-9a-f]{32}$/;
    return $out;
}

sub identical {
    my ($a, $b) = @_;
    return system('cmp', '-s', $a, $b) == 0;
}

# ---------------------------------------------------------------- btrfs

my $btrfs_ok = eval {
    run_command(['truncate', '-s', '2G', $BTRFS_IMG]);
    push @cleanup, sub { unlink $BTRFS_IMG };

    my $loop = sh("losetup --find --show $BTRFS_IMG");
    chomp $loop;
    die "no loop device\n" if !$loop;
    push @cleanup, sub { sh("losetup -d $loop") };

    run_command(['mkfs.btrfs', '-q', '-f', $loop]);
    mkpath $BTRFS_MNT;
    run_command(['mount', $loop, $BTRFS_MNT]);
    push @cleanup, sub {
        for my $s (reverse split /\n/, sh("btrfs subvolume list -o $BTRFS_MNT | awk '{print \$NF}'")) {
            sh("btrfs -q subvolume delete '$BTRFS_MNT/$s'");
        }
        sh("umount $BTRFS_MNT");
        rmtree $BTRFS_MNT;
    };
    mkpath "$BTRFS_MNT/images";
    1;
};
if (!$btrfs_ok) {
    diag("btrfs setup failed: $@");
    SKIP: { skip 'btrfs setup failed', 11 }
} else {
    my $C = 'PVE::Storage::BTRFSPlugin';
    my $scfg = { path => $BTRFS_MNT, type => 'btrfs', content => { images => 1 } };

    my $src = $C->alloc_image('bt', $scfg, 100, 'raw', undef, 64 * 1024);
    my $srcpath = $C->filesystem_path($scfg, $src);
    sh("dd if=/dev/urandom of=$srcpath bs=1M count=16 conv=notrunc,fsync status=none");

    $C->volume_snapshot($scfg, 'bt', $src, 'snap1');
    my $snappath = $C->filesystem_path($scfg, $src, 'snap1');
    sh("dd if=/dev/urandom of=$srcpath bs=1M count=16 conv=notrunc,fsync status=none");
    ok(!identical($srcpath, $snappath), 'btrfs: source diverged from its snapshot');

    # THE multi-disk case: the core prepares every disk before starting any of them.
    my $a = $C->copy_image_prepare($scfg, 'bt', $src, $scfg, 'bt', 201, undef, {});
    my $b = $C->copy_image_prepare($scfg, 'bt', $src, $scfg, 'bt', 201, undef, {});
    isnt($a, $b, 'btrfs: two prepares for one target VM reserve different names');

    $C->copy_image_start($scfg, 'bt', $src, $scfg, 'bt', $a, undef);

    # After start() but BEFORE status() cleans up, the reserved name must still be held.
    # start() swaps the copy in with RENAME_EXCHANGE precisely so the name is never
    # momentarily free; a plain park-then-rename loses the reservation exactly here, and
    # a concurrent allocation could then take the name out from under the caller's
    # rollback. Checked between the two calls on purpose -- that is the fragile moment.
    my ($a_name) = $a =~ m{/(.*)$};
    isnt(
        $C->find_free_diskname('bt', $scfg, 201, 'raw', 1), $a_name,
        'btrfs: the reserved name is still held across the swap',
    );

    my $st = $C->copy_image_status($scfg, 'bt', $a, undef);
    is($st->{state}, 'complete', 'btrfs: status complete on the first poll');
    my $apath = $C->filesystem_path($scfg, $a);
    ok(identical($apath, $srcpath), 'btrfs: copy matches the source');

    my $snapcopy = $C->copy_image_prepare($scfg, 'bt', $src, $scfg, 'bt', 202, 'snap1', {});
    $C->copy_image_start($scfg, 'bt', $src, $scfg, 'bt', $snapcopy, 'snap1');
    $C->copy_image_status($scfg, 'bt', $snapcopy, undef);
    # NB: assign filesystem_path() to a scalar first. It returns ($path, $vmid, $vtype)
    # in list context, and sub arguments ARE list context -- passing the call directly
    # would hand identical() the vmid as its second path.
    my $snapcopy_path = $C->filesystem_path($scfg, $snapcopy);
    ok(
        identical($snapcopy_path, $snappath),
        'btrfs: a copy from a snapshot holds the SNAPSHOT content, not live data',
    );

    # Independence: hash the copy, destroy the source outright, hash again.
    my $before = md5_of($apath);
    $C->free_image('bt', $scfg, $src, 0);
    ok(!-e $srcpath, 'btrfs: source really is gone');
    is($before, md5_of($apath), 'btrfs: copy is unaffected by deleting the source');
    unlike(
        sh("find $BTRFS_MNT -maxdepth 4 -name '*.copytmp' -o -name '*.copynew'"), qr/\S/,
        'btrfs: no parked or staging placeholder left behind',
    );

    # Failure path: same as the lvmthin case -- a placeholder left by a copy that died
    # between start() and status() must not wedge the name, since rename() refuses to
    # park onto an existing path and the leftover is invisible to list_images().
    my $stale = $C->copy_image_prepare($scfg, 'bt', $a, $scfg, 'bt', 203, undef, {});
    my $stale_subvol = $C->filesystem_path($scfg, $stale);
    $stale_subvol =~ s|/disk\.raw$||;
    rename($stale_subvol, "$stale_subvol.copytmp")
        or die "could not stage the leaked-placeholder case - $!\n";
    my $reused = eval { $C->copy_image_prepare($scfg, 'bt', $a, $scfg, 'bt', 203, undef, {}) };
    ok(defined($reused), 'btrfs: a leaked placeholder does not wedge the disk name')
        or diag("prepare failed: $@");
    if (defined($reused)) {
        $C->copy_image_start($scfg, 'bt', $a, $scfg, 'bt', $reused, undef);
        $C->copy_image_status($scfg, 'bt', $reused, undef);
        my $reused_path = $C->filesystem_path($scfg, $reused);
        ok(identical($reused_path, $apath), 'btrfs: the retried copy is correct');
    } else {
        ok(0, 'btrfs: the retried copy is correct');
    }
}

# ---------------------------------------------------------------- lvmthin

my $lvm_ok = eval {
    run_command(['truncate', '-s', '3G', $LVM_IMG]);
    push @cleanup, sub { unlink $LVM_IMG };

    my $loop = sh("losetup --find --show $LVM_IMG");
    chomp $loop;
    die "no loop device\n" if !$loop;
    # Detach as its own entry, registered IMMEDIATELY. Folding it into the entry pushed
    # after vgcreate would leak the loop device whenever pvcreate or vgcreate fails --
    # the eval catches that, the test SKIPs "cleanly", and the device stays attached.
    push @cleanup, sub { sh("losetup -d $loop") };

    run_command(['pvcreate', '-qq', '-f', $loop]);
    run_command(['vgcreate', '-qq', $VG, $loop]);
    push @cleanup, sub { sh("vgremove -qq -f $VG"); sh("pvremove -qq -f $loop") };

    run_command(['lvcreate', '-qq', '--type', 'thin-pool', '-L', '2G', '-n', 'tp', $VG]);
    1;
};
if (!$lvm_ok) {
    diag("lvm setup failed: $@");
    SKIP: { skip 'lvm setup failed', 10 }
} else {
    my $C = 'PVE::Storage::LvmThinPlugin';
    my $scfg = { vgname => $VG, thinpool => 'tp', type => 'lvmthin', content => { images => 1 } };
    my $act = sub { sh("lvchange -ay -K $VG/$_[0]") };

    my $src = $C->alloc_image('lt', $scfg, 100, 'raw', undef, 64 * 1024);
    $act->($src);
    sh("dd if=/dev/urandom of=/dev/$VG/$src bs=1M count=8 conv=fsync status=none");

    $C->volume_snapshot($scfg, 'lt', $src, 'snap1');
    my $snapdev = "/dev/$VG/snap_${src}_snap1";
    $act->("snap_${src}_snap1");
    sh("dd if=/dev/urandom of=/dev/$VG/$src bs=1M count=8 conv=fsync status=none");
    ok(!identical("/dev/$VG/$src", $snapdev), 'lvmthin: source diverged from its snapshot');

    my $a = $C->copy_image_prepare($scfg, 'lt', $src, $scfg, 'lt', 201, undef, {});
    my $b = $C->copy_image_prepare($scfg, 'lt', $src, $scfg, 'lt', 201, undef, {});
    isnt($a, $b, 'lvmthin: two prepares for one target VM reserve different names');

    $C->copy_image_start($scfg, 'lt', $src, $scfg, 'lt', $a, undef);
    my $st = $C->copy_image_status($scfg, 'lt', $a, undef);
    is($st->{state}, 'complete', 'lvmthin: status complete on the first poll');
    $act->($a);
    ok(identical("/dev/$VG/$a", "/dev/$VG/$src"), 'lvmthin: copy matches the source');

    my $snapcopy = $C->copy_image_prepare($scfg, 'lt', $src, $scfg, 'lt', 202, 'snap1', {});
    $C->copy_image_start($scfg, 'lt', $src, $scfg, 'lt', $snapcopy, 'snap1');
    $C->copy_image_status($scfg, 'lt', $snapcopy, undef);
    $act->($snapcopy);
    ok(
        identical("/dev/$VG/$snapcopy", $snapdev),
        'lvmthin: a copy from a snapshot holds the SNAPSHOT content, not live data',
    );

    # Independence: hash the copy, destroy the source outright, hash again.
    my $before = md5_of("/dev/$VG/$a");
    $C->volume_snapshot_delete($scfg, 'lt', $src, 'snap1');
    $C->free_image('lt', $scfg, $src, 0);
    ok(!-e "/dev/$VG/$src", 'lvmthin: source really is gone');
    is($before, md5_of("/dev/$VG/$a"), 'lvmthin: copy is unaffected by deleting the source');

    unlike(
        sh("lvs --noheadings -o lv_name $VG"), qr/copytmp-/,
        'lvmthin: no parked placeholder left behind',
    );

    # Failure path: a placeholder left by an earlier copy that died between start() and
    # status() must not wedge the name. Without the reaping in prepare(), 'lvrename'
    # cannot park onto the existing name and EVERY later copy to it fails -- and the
    # leftover is invisible to list_images(), so nobody would know why.
    my $stale = $C->copy_image_prepare($scfg, 'lt', $a, $scfg, 'lt', 203, undef, {});
    sh("lvrename $VG $stale copytmp-$stale");
    my $reused = eval { $C->copy_image_prepare($scfg, 'lt', $a, $scfg, 'lt', 203, undef, {}) };
    ok(defined($reused), 'lvmthin: a leaked placeholder does not wedge the disk name')
        or diag("prepare failed: $@");
    if (defined($reused)) {
        $C->copy_image_start($scfg, 'lt', $a, $scfg, 'lt', $reused, undef);
        $C->copy_image_status($scfg, 'lt', $reused, undef);
        $act->($reused);
        ok(identical("/dev/$VG/$reused", "/dev/$VG/$a"), 'lvmthin: the retried copy is correct');
    } else {
        ok(0, 'lvmthin: the retried copy is correct');
    }
}

cleanup_all();
