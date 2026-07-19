package PVE::Storage::LvmThinPlugin;

use strict;
use warnings;

use IO::File;

use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command trim);

use PVE::Storage::Plugin;
use PVE::Storage::LVMPlugin;

# see: man lvmthin
# lvcreate -n ThinDataLV -L LargeSize VG
# lvconvert --type thin-pool VG/ThinDataLV
# lvcreate -n pvepool -L 20G pve
# lvconvert --type thin-pool pve/pvepool

# NOTE: volumes which were created as linked clones of another base volume
# are currently not tracking this relationship in their volume IDs. this is
# generally not a problem, as LVM thin allows deletion of such base volumes
# without affecting the linked clones. this leads to increased disk usage
# when migrating LVM-thin volumes, which is normally prevented for linked clones.

use base qw(PVE::Storage::LVMPlugin);

sub type {
    return 'lvmthin';
}

sub plugindata {
    return {
        content => [{ images => 1, rootdir => 1 }, { images => 1, rootdir => 1 }],
        'sensitive-properties' => {},
    };
}

sub properties {
    return {
        thinpool => {
            description => "LVM thin pool LV name.",
            type => 'string',
            format => 'pve-storage-vgname',
        },
    };
}

sub options {
    return {
        thinpool => { fixed => 1 },
        vgname => { fixed => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        bwlimit => { optional => 1 },
        'copy-offload' => { optional => 1 },
        'copy-offload-timeout' => { optional => 1 },
    };
}

# NOTE: the fourth and fifth element of the returned array are always
# undef, even if the volume is a linked clone of another volume. see note
# at beginning of file.
sub parse_volname {
    my ($class, $volname) = @_;

    PVE::Storage::Plugin::parse_lvm_name($volname);

    if ($volname =~ m/^((vm|base)-(\d+)-\S+)$/) {
        return ('images', $1, $3, undef, undef, $2 eq 'base', 'raw');
    }

    die "unable to parse lvm volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $vg = $scfg->{vgname};

    my $path = defined($snapname) ? "/dev/$vg/snap_${name}_$snapname" : "/dev/$vg/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

# lvcreate on trixie does not accept --setautoactivation for thin LVs yet, so set it via lvchange
# TODO PVE 10: evaluate if lvcreate accepts --setautoactivation
my $set_lv_autoactivation = sub {
    my ($vg, $lv, $autoactivation) = @_;

    my $cmd = [
        '/sbin/lvchange', '--setautoactivation', $autoactivation ? 'y' : 'n', "$vg/$lv",
    ];
    eval { run_command($cmd); };
    warn "could not set autoactivation: $@" if $@;
};

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
        if $name && $name !~ m/^vm-$vmid-/;

    my $vgs = PVE::Storage::LVMPlugin::lvm_vgs();

    my $vg = $scfg->{vgname};

    die "no such volume group '$vg'\n" if !defined($vgs->{$vg});

    $name = $class->find_free_diskname($storeid, $scfg, $vmid)
        if !$name;

    my $cmd = [
        '/sbin/lvcreate',
        '-aly',
        '-V',
        "${size}k",
        '--name',
        $name,
        '--thinpool',
        "$vg/$scfg->{thinpool}",
    ];

    run_command($cmd, errmsg => "lvcreate '$vg/$name' error");
    $set_lv_autoactivation->($vg, $name, 0);

    return $name;
}

# Where copy_image_start() parks the reservation while it creates the snapshot.
#
# A PREFIX, not a suffix: list_images() selects on m/^(vm|base)-(\d+)-/ and
# parse_volname() accepts m/^((vm|base)-(\d+)-\S+)$/, so 'vm-101-disk-0.copytmp' would
# be a perfectly valid volume name and would show up as a disk belonging to VM 101 --
# a phantom the GUI offers to attach as an unused disk, and one that outlives the copy
# if it ever leaks. Prefixing puts it outside both patterns.
my sub parked_name {
    my ($volname) = @_;
    return "copytmp-$volname";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $vg = $scfg->{vgname};

    my $lvs = PVE::Storage::LVMPlugin::lvm_list_volumes($vg);

    if (my $dat = $lvs->{ $scfg->{vgname} }) {

        # remove all volume snapshots first
        foreach my $lv (keys %$dat) {
            next if $lv !~ m/^snap_${volname}_${PVE::JSONSchema::CONFIGID_RE}$/;
            my $cmd = ['/sbin/lvremove', '-f', "$vg/$lv"];
            run_command($cmd, errmsg => "lvremove snapshot '$vg/$lv' error");
        }

        # a copy placeholder parked under this name, if a copy died mid-flight
        my $parked = parked_name($volname);
        if ($dat->{$parked}) {
            my $cmd = ['/sbin/lvremove', '-f', "$vg/$parked"];
            run_command($cmd, errmsg => "lvremove copy placeholder '$vg/$parked' error");
        }

        # finally remove original (if exists)
        if ($dat->{$volname}) {
            my $cmd = ['/sbin/lvremove', '-f', "$vg/$volname"];
            run_command($cmd, errmsg => "lvremove '$vg/$volname' error");
        }
    }

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $vgname = $scfg->{vgname};

    $cache->{lvs} = PVE::Storage::LVMPlugin::lvm_list_volumes() if !$cache->{lvs};

    my $res = [];

    if (my $dat = $cache->{lvs}->{$vgname}) {

        foreach my $volname (keys %$dat) {

            next if $volname !~ m/^(vm|base)-(\d+)-/;
            my $owner = $2;

            my $info = $dat->{$volname};

            next if $info->{lv_type} ne 'V';

            next if $info->{pool_lv} ne $scfg->{thinpool};

            my $volid = "$storeid:$volname";

            if ($vollist) {
                my $found = grep { $_ eq $volid } @$vollist;
                next if !$found;
            } else {
                next if defined($vmid) && ($owner ne $vmid);
            }

            push @$res,
                {
                    volid => $volid,
                    format => 'raw',
                    size => $info->{lv_size},
                    vmid => $owner,
                    ctime => $info->{ctime},
                };
        }
    }

    return $res;
}

sub list_thinpools {
    my ($vg) = @_;

    my $lvs = PVE::Storage::LVMPlugin::lvm_list_volumes($vg);
    my $thinpools = [];

    foreach my $vg (keys %$lvs) {
        foreach my $lvname (keys %{ $lvs->{$vg} }) {
            next if $lvs->{$vg}->{$lvname}->{lv_type} ne 't';
            my $lv = $lvs->{$vg}->{$lvname};
            $lv->{lv} = $lvname;
            $lv->{vg} = $vg;
            push @$thinpools, $lv;
        }
    }

    return $thinpools;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $lvs = $cache->{lvs} ||= PVE::Storage::LVMPlugin::lvm_list_volumes();

    return if !$lvs->{ $scfg->{vgname} };

    my $info = $lvs->{ $scfg->{vgname} }->{ $scfg->{thinpool} };

    return if !$info || $info->{lv_type} ne 't' || !$info->{lv_size};

    return (
        $info->{lv_size},
        $info->{lv_size} - $info->{used},
        $info->{used},
        $info->{lv_state} eq 'a' ? 1 : 0,
    );
}

my $activate_lv = sub {
    my ($vg, $lv, $cache) = @_;

    my $lvs = $cache->{lvs} ||= PVE::Storage::LVMPlugin::lvm_list_volumes();

    die "no such logical volume $vg/$lv\n" if !$lvs->{$vg} || !$lvs->{$vg}->{$lv};

    return if $lvs->{$vg}->{$lv}->{lv_state} eq 'a';

    run_command(
        ['lvchange', '-ay', '-K', "$vg/$lv"],
        errmsg => "activating LV '$vg/$lv' failed",
    );

    $lvs->{$vg}->{$lv}->{lv_state} = 'a'; # update cache

    return;
};

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $class->SUPER::activate_storage($storeid, $scfg, $cache);

    $activate_lv->($scfg->{vgname}, $scfg->{thinpool}, $cache);
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $vg = $scfg->{vgname};
    my $lv = $snapname ? "snap_${volname}_$snapname" : $volname;

    $activate_lv->($vg, $lv, $cache);
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    return if !$snapname && $volname !~ /^base-/; # other volumes are kept active

    my $vg = $scfg->{vgname};
    my $lv = $snapname ? "snap_${volname}_$snapname" : $volname;

    run_command(['lvchange', '-an', "$vg/$lv"], errmsg => "deactivate_volume '$vg/$lv' error");

    $cache->{lvs}->{$vg}->{$lv}->{lv_state} = '-' # update cache
        if $cache->{lvs} && $cache->{lvs}->{$vg} && $cache->{lvs}->{$vg}->{$lv};

    return;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $vg = $scfg->{vgname};

    my $lv;

    if ($snap) {
        $lv = "$vg/snap_${volname}_$snap";
    } else {
        my ($vtype, undef, undef, undef, undef, $isBase, $format) = $class->parse_volname($volname);

        die "clone_image only works on base images\n" if !$isBase;

        $lv = "$vg/$volname";
    }

    my $name = $class->find_free_diskname($storeid, $scfg, $vmid);

    my $cmd = ['/sbin/lvcreate', '-n', $name, '-prw', '-kn', '-s', $lv];
    run_command($cmd, errmsg => "clone image '$lv' error");
    $set_lv_autoactivation->($vg, $name, 0);

    return $name;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = $class->parse_volname($volname);

    die "create_base not possible with base image\n" if $isBase;

    my $vg = $scfg->{vgname};
    my $lvs = PVE::Storage::LVMPlugin::lvm_list_volumes($vg);

    if (my $dat = $lvs->{$vg}) {
        # to avoid confusion, reject if we find volume snapshots
        foreach my $lv (keys %$dat) {
            die "unable to create base volume - found snaphost '$lv'\n"
                if $lv =~ m/^snap_${volname}_(\w+)$/;
        }
    }

    my $newname = $name;
    $newname =~ s/^vm-/base-/;

    my $cmd = ['/sbin/lvrename', $vg, $volname, $newname];
    run_command($cmd, errmsg => "lvrename '$vg/$volname' => '$vg/$newname' error");

    # set read-only and activationskip flags
    $cmd = ['/sbin/lvchange', '-pr', '-ky', "$vg/$newname"];
    eval { run_command($cmd); };
    warn $@ if $@;

    # LVM warns when changing properties and activation at the same time, so inactivate separately
    $cmd = ['/sbin/lvchange', '-an', "$vg/$newname"];
    eval { run_command($cmd); };
    warn $@ if $@;

    my $newvolname = $newname;

    return $newvolname;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    die "resizing a snapshot is not supported for $class\n" if $snapname;

    return $class->SUPER::volume_resize($scfg, $storeid, $volname, $size, $running, $snapname);
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $vg = $scfg->{vgname};
    my $snapvol = "snap_${volname}_$snap";

    my $cmd = ['/sbin/lvcreate', '-n', $snapvol, '-pr', '-s', "$vg/$volname"];
    run_command($cmd, errmsg => "lvcreate snapshot '$vg/$snapvol' error");
    # disabling autoactivation not needed, as -s defaults to --setautoactivationskip y
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $vg = $scfg->{vgname};
    my $snapvol = "snap_${volname}_$snap";

    my $cmd = ['/sbin/lvremove', '-f', "$vg/$volname"];
    run_command($cmd, errmsg => "lvremove '$vg/$volname' error");

    $cmd = ['/sbin/lvcreate', '-kn', '-n', $volname, '-s', "$vg/$snapvol"];
    run_command($cmd, errmsg => "lvm rollback '$vg/$snapvol' error");
    $set_lv_autoactivation->($vg, $volname, 0);
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $vg = $scfg->{vgname};
    my $snapvol = "snap_${volname}_$snap";

    my $cmd = ['/sbin/lvremove', '-f', "$vg/$snapvol"];
    run_command($cmd, errmsg => "lvremove snapshot '$vg/$snapvol' error");
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        snapshot => { current => 1 },
        clone => { base => 1, snap => 1 },
        template => { current => 1 },
        copy => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        rename => { current => 1 },
        # A thin snapshot is instant, allocates nothing, and is independent of its
        # origin straight away -- see the note at the top of this file: the origin can
        # be deleted without affecting it. Snapshots of a snapshot work too, so all
        # three keys apply.
        'copy-offload-atomic' => { base => 1, current => 1, snap => 1 },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = $class->parse_volname($volname);

    my $key = undef;
    if ($snapname) {
        $key = 'snap';
    } else {
        $key = $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

sub volume_import {
    my (
        $class,
        $scfg,
        $storeid,
        $fh,
        $volname,
        $format,
        $snapshot,
        $base_snapshot,
        $with_snapshots,
        $allow_rename,
    ) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $file_format) =
        $class->parse_volname($volname);

    if (!$isBase) {
        return $class->SUPER::volume_import(
            $scfg,
            $storeid,
            $fh,
            $volname,
            $format,
            $snapshot,
            $base_snapshot,
            $with_snapshots,
            $allow_rename,
        );
    } else {
        my $tempname;
        my $vg = $scfg->{vgname};
        my $lvs = PVE::Storage::LVMPlugin::lvm_list_volumes($vg);
        if ($lvs->{$vg}->{$volname}) {
            die "volume $vg/$volname already exists\n" if !$allow_rename;
            warn "volume $vg/$volname already exists - importing with a different name\n";

            $tempname = $class->find_free_diskname($storeid, $scfg, $vmid);
        } else {
            $tempname = $volname;
            $tempname =~ s/base/vm/;
        }

        my $newvolid = $class->SUPER::volume_import(
            $scfg,
            $storeid,
            $fh,
            $tempname,
            $format,
            $snapshot,
            $base_snapshot,
            $with_snapshots,
            $allow_rename,
        );
        ($storeid, my $newname) = PVE::Storage::Plugin::parse_volume_id($newvolid);

        $volname = $class->create_base($storeid, $scfg, $newname);
    }

    return "$storeid:$volname";
}

# used in LVMPlugin->volume_import
sub volume_import_write {
    my ($class, $input_fh, $output_file) = @_;
    run_command(
        ['dd', "of=$output_file", 'conv=sparse', 'bs=64k'],
        input => '<&' . fileno($input_fh),
    );
}

sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;

    die "rename_snapshot is not supported for $class";
}

# ---- storage-offloaded full copy via thin snapshot --------------------------------
#
# 'lvcreate -s' on a thin LV is instant, allocates no data blocks, and -- unlike a ZFS
# clone -- does not pin its origin: the thin pool reference counts blocks, so the origin
# can be removed while the copy lives on. That is the note at the top of this file, and
# it is exactly what 'copy-offload-atomic' requires, so there is no background work and
# copy_image_status() is complete on the first poll.
#
# This is the same primitive clone_image() already uses for linked clones. The
# difference is only in what PVE believes afterwards: a linked clone records a
# dependency it must respect, while this path is free to hand back a volume with no
# recorded parent, because thin snapshots genuinely have none.

my sub thin_lv_exists {
    my ($vg, $lv) = @_;
    my $lvs = PVE::Storage::LVMPlugin::lvm_list_volumes($vg);
    return defined($lvs->{$vg}) && defined($lvs->{$vg}->{$lv});
}

sub copy_image_prepare {
    my (
        $class, $scfg, $storeid, $volname,
        $target_scfg, $target_storeid, $target_vmid, $snap, $opts,
    ) = @_;

    my $format = $opts->{format} // 'raw';
    die "lvmthin copy offload cannot produce format '$format'\n" if $format ne 'raw';

    my ($vtype) = $class->parse_volname($volname);
    die "copy offload only handles VM images, not '$vtype'\n" if $vtype ne 'images';

    # A thin snapshot shares blocks with its origin inside one pool, so it cannot leave
    # that pool. Copying to another VG or another thinpool is a real data move and has
    # to take the normal host-side path.
    my $vg = $scfg->{vgname};
    die "copy offload requires source and target in the same volume group\n"
        if ($target_scfg->{vgname} // '') ne $vg;
    die "copy offload requires source and target in the same thin pool\n"
        if ($target_scfg->{thinpool} // '') ne ($scfg->{thinpool} // '');

    my $src_lv = defined($snap) ? "snap_${volname}_$snap" : $volname;
    die "cannot copy '$volname': source volume '$src_lv' does not exist\n"
        if !thin_lv_exists($vg, $src_lv);

    my $name = $class->find_free_diskname($target_storeid, $target_scfg, $target_vmid);

    # Reap a placeholder left by an earlier copy that died between start() and
    # status(). It is not merely litter: 'lvrename' below refuses to park onto an
    # existing name, so without this every future offloaded copy to this name fails.
    # Doing it here is safe -- we hold the target storage lock and are outside any
    # freeze -- and the name is ours, since find_free_diskname() just handed it out.
    my $stale = parked_name($name);
    if (thin_lv_exists($vg, $stale)) {
        warn "removing stale copy placeholder '$vg/$stale'\n";
        run_command(
            ['/sbin/lvremove', '-f', "$vg/$stale"],
            errmsg => "lvremove stale placeholder '$vg/$stale' error",
        );
    }

    # Actually create the target, do not just pick a name. The caller runs this under
    # the target storage lock and releases it before copy_image_start(), so a name that
    # was merely chosen could be taken by a concurrent allocation in between -- and the
    # caller's rollback would then free a volume belonging to that other operation.
    #
    # A thin LV is virtual, so this placeholder allocates no data blocks whatever size
    # it claims; 1k is simply the smallest lvcreate accepts and rounds up.
    my $cmd = [
        '/sbin/lvcreate', '-aly', '-V', '1k', '--name', $name,
        '--thinpool', "$vg/$scfg->{thinpool}",
    ];
    run_command($cmd, errmsg => "lvcreate placeholder '$vg/$name' error");
    $set_lv_autoactivation->($vg, $name, 0);

    return $name;
}

sub copy_image_start {
    my (
        $class, $scfg, $storeid, $volname,
        $target_scfg, $target_storeid, $target_volname, $snap,
    ) = @_;

    my $vg = $scfg->{vgname};

    # Snapshot the source the caller asked for. Falling back to the current LV when a
    # snapshot was requested would silently copy live data instead.
    my $src_lv = defined($snap) ? "snap_${volname}_$snap" : $volname;

    # copy_image_prepare() reserved the name with a placeholder, and 'lvcreate -s'
    # cannot write into a name that already exists. Rename the placeholder aside rather
    # than removing it, so the reserved name is never momentarily free for a concurrent
    # find_free_diskname() to hand out.
    my $parked = parked_name($target_volname);
    run_command(
        ['/sbin/lvrename', $vg, $target_volname, $parked],
        errmsg => "lvrename placeholder '$vg/$target_volname' error",
    );

    eval {
        # ONLY the snapshot. It is what fixes the point in time; everything else this
        # copy needs is done by copy_image_status(), outside the freeze.
        my $cmd = ['/sbin/lvcreate', '-n', $target_volname, '-prw', '-kn', '-s', "$vg/$src_lv"];
        run_command($cmd, errmsg => "thin snapshot of '$vg/$src_lv' error");
    };
    if (my $err = $@) {
        # Put the reservation back so the caller's rollback still finds the volume it
        # was given, and leave the source untouched. If that fails too, remove the
        # parked LV rather than leaving an orphan: the rollback frees $target_volname,
        # which by then names nothing, so nothing else would ever reap it.
        eval {
            run_command(
                ['/sbin/lvrename', $vg, $parked, $target_volname],
                errmsg => "restoring placeholder '$vg/$target_volname' error",
            );
        };
        if (my $rerr = $@) {
            eval { run_command(['/sbin/lvremove', '-f', "$vg/$parked"]) };
            $err .= "additionally, could not restore the reserved name: $rerr";
            $err .= "and '$vg/$parked' is left behind\n" if $@;
        }
        die $err;
    }

    # The parked placeholder is deliberately NOT removed here. This runs while the
    # caller may hold a guest filesystem frozen, and every LVM command takes VG
    # metadata locks that can queue behind other activity on the node -- for a
    # multi-disk VM those add up inside a single freeze. Only the snapshot above fixes
    # the point in time; removal is cleanup, and copy_image_status() does it outside.
    return;
}

sub copy_image_status {
    my ($class, $scfg, $storeid, $volname, $source) = @_;

    # $volname is the TARGET. The thin snapshot is complete and independent the moment
    # lvcreate returns, so there is nothing to poll and nothing of the source to
    # release. What is left is dropping the placeholder copy_image_start() parked,
    # which happens here to keep it out of the freeze window.
    my $vg = $scfg->{vgname};

    # Everything here is best effort ON PURPOSE, including the existence check. This
    # runs in the caller's poll loop, and dying makes it free a copy that is already
    # complete, correct and independent -- losing real data because a cleanup probe hit
    # a transient LVM lock, which is exactly the contention this plugin already works
    # around elsewhere. Deferring the autoactivation flag to here for the same reason it
    # is not done in start(): it is metadata housekeeping that takes the same VG lock.
    eval {
        my $parked = parked_name($volname);
        if (thin_lv_exists($vg, $parked)) {
            run_command(
                ['/sbin/lvremove', '-f', "$vg/$parked"],
                errmsg => "lvremove placeholder '$vg/$parked' error",
            );
        }
    };
    warn $@ if $@;

    $set_lv_autoactivation->($vg, $volname, 0);

    return { state => 'complete' };
}

1;
