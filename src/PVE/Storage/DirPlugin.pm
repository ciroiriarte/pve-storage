package PVE::Storage::DirPlugin;

use strict;
use warnings;

use Cwd;
use Encode qw(decode encode);
use File::Path;
use File::Spec;
use IO::File;
use JSON;
use POSIX;

use PVE::Storage::Plugin;
use PVE::GuestImport::OVF;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

# Configuration

sub type {
    return 'dir';
}

sub plugindata {
    return {
        content => [
            {
                images => 1,
                rootdir => 1,
                vztmpl => 1,
                iso => 1,
                backup => 1,
                snippets => 1,
                none => 1,
                import => 1,
            },
            { images => 1, rootdir => 1 },
        ],
        format => [{ raw => 1, qcow2 => 1, vmdk => 1, subvol => 1 }, 'raw'],
        'sensitive-properties' => {},
    };
}

sub properties {
    return {
        path => {
            description => "File system path.",
            type => 'string',
            format => 'pve-storage-path',
        },
        mkdir => {
            description =>
                "Create the directory if it doesn't exist and populate it with default sub-dirs."
                . " NOTE: Deprecated, use the 'create-base-path' and 'create-subdirs' options instead.",
            type => 'boolean',
            default => 'yes',
        },
        'create-base-path' => {
            description => "Create the base directory if it doesn't exist.",
            type => 'boolean',
            default => 'yes',
        },
        'create-subdirs' => {
            description => "Populate the directory with the default structure.",
            type => 'boolean',
            default => 'yes',
        },
        is_mountpoint => {
            description => "Assume the given path is an externally managed mountpoint "
                . "and consider the storage offline if it is not mounted. "
                . "Using a boolean (yes/no) value serves as a shortcut to using the target path in this field.",
            type => 'string',
            default => 'no',
        },
        bwlimit => get_standard_option('bwlimit'),
    };
}

sub options {
    return {
        path => { fixed => 1 },
        'content-dirs' => { optional => 1 },
        nodes => { optional => 1 },
        shared => { optional => 1 },
        disable => { optional => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
        content => { optional => 1 },
        format => { optional => 1 },
        mkdir => { optional => 1 },
        'create-base-path' => { optional => 1 },
        'create-subdirs' => { optional => 1 },
        is_mountpoint => { optional => 1 },
        bwlimit => { optional => 1 },
        preallocation => { optional => 1 },
        'snapshot-as-volume-chain' => { optional => 1, fixed => 1 },
        'copy-offload' => { optional => 1 },
        'copy-offload-timeout' => { optional => 1 },
    };
}

# Storage implementation
#

# NOTE: should ProcFSTools::is_mounted accept an optional cache like this?
sub path_is_mounted {
    my ($mountpoint, $mountdata) = @_;

    $mountpoint = Cwd::realpath($mountpoint); # symlinks
    return 0 if !defined($mountpoint); # path does not exist

    $mountdata = PVE::ProcFSTools::parse_proc_mounts() if !$mountdata;
    return 1 if grep { $_->[1] eq $mountpoint } @$mountdata;
    return undef;
}

sub parse_is_mountpoint {
    my ($scfg) = @_;
    my $is_mp = $scfg->{is_mountpoint};
    return undef if !defined $is_mp;
    if (defined(my $bool = PVE::JSONSchema::parse_boolean($is_mp))) {
        return $bool ? $scfg->{path} : undef;
    }
    return $is_mp; # contains a path
}

# FIXME move into 'get_volume_attribute' when removing 'get_volume_notes'
my $get_volume_notes_impl = sub {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my ($vtype) = $class->parse_volname($volname);
    return if $vtype ne 'backup';

    my $path = $class->filesystem_path($scfg, $volname);
    $path .= $class->SUPER::NOTES_EXT;

    if (-f $path) {
        my $data = PVE::Tools::file_get_contents($path);
        return eval { decode('UTF-8', $data, 1) } // $data;
    }

    return '';
};

# FIXME remove on the next APIAGE reset.
# Deprecated, use get_volume_attribute instead.
sub get_volume_notes {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    return $get_volume_notes_impl->($class, $scfg, $storeid, $volname, $timeout);
}

# FIXME move into 'update_volume_attribute' when removing 'update_volume_notes'
my $update_volume_notes_impl = sub {
    my ($class, $scfg, $storeid, $volname, $notes, $timeout) = @_;

    my ($vtype) = $class->parse_volname($volname);
    die "only backups can have notes\n" if $vtype ne 'backup';

    my $path = $class->filesystem_path($scfg, $volname);
    $path .= $class->SUPER::NOTES_EXT;

    if (defined($notes) && $notes ne '') {
        my $encoded = encode('UTF-8', $notes);
        PVE::Tools::file_set_contents($path, $encoded);
    } else {
        unlink $path or $! == ENOENT or die "could not delete notes - $!\n";
    }
    return;
};

# FIXME remove on the next APIAGE reset.
# Deprecated, use update_volume_attribute instead.
sub update_volume_notes {
    my ($class, $scfg, $storeid, $volname, $notes, $timeout) = @_;
    return $update_volume_notes_impl->($class, $scfg, $storeid, $volname, $notes, $timeout);
}

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;

    if ($attribute eq 'notes') {
        return $get_volume_notes_impl->($class, $scfg, $storeid, $volname);
    }

    my ($vtype) = $class->parse_volname($volname);
    return if $vtype ne 'backup';

    if ($attribute eq 'protected') {
        my $path = $class->filesystem_path($scfg, $volname);
        return -e PVE::Storage::protection_file_path($path) ? 1 : 0;
    }

    return;
}

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;

    if ($attribute eq 'notes') {
        return $update_volume_notes_impl->($class, $scfg, $storeid, $volname, $value);
    }

    my ($vtype) = $class->parse_volname($volname);
    die "only backups support attribute '$attribute'\n" if $vtype ne 'backup';

    if ($attribute eq 'protected') {
        my $path = $class->filesystem_path($scfg, $volname);
        my $protection_path = PVE::Storage::protection_file_path($path);

        return if !((-e $protection_path) xor $value); # protection status already correct

        if ($value) {
            my $fh = IO::File->new($protection_path, O_CREAT, 0644)
                or die "unable to create protection file '$protection_path' - $!\n";
            close($fh);
        } else {
            unlink $protection_path
                or $! == ENOENT
                or die "could not delete protection file '$protection_path' - $!\n";
        }

        return;
    }

    die "attribute '$attribute' is not supported for storage type '$scfg->{type}'\n";
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    if (defined(my $mp = parse_is_mountpoint($scfg))) {
        $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
            if !$cache->{mountdata};

        return undef if !path_is_mounted($mp, $cache->{mountdata});
    }

    return $class->SUPER::status($storeid, $scfg, $cache);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $path = $scfg->{path};

    my $mp = parse_is_mountpoint($scfg);
    if (defined($mp) && !path_is_mounted($mp, $cache->{mountdata})) {
        die "unable to activate storage '$storeid' - "
            . "directory is expected to be a mount point but is not mounted: '$mp'\n";
    }

    $class->config_aware_base_mkdir($scfg, $path);
    $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub check_config {
    my ($self, $sectionId, $config, $create, $skipSchemaCheck) = @_;
    my $opts =
        PVE::SectionConfig::check_config($self, $sectionId, $config, $create, $skipSchemaCheck);
    return $opts if !$create;
    if ($opts->{path} !~ m|^/[-/a-zA-Z0-9_.@]+$|) {
        die "illegal path for directory storage: $opts->{path}\n";
    }
    # remove trailing slashes from path
    $opts->{path} = File::Spec->canonpath($opts->{path});
    return $opts;
}

sub get_import_metadata {
    my ($class, $scfg, $volname, $storeid) = @_;

    my ($vtype, $name, undef, undef, undef, undef, $fmt) = $class->parse_volname($volname);
    die "invalid content type '$vtype'\n" if $vtype ne 'import';
    die "invalid format\n" if $fmt ne 'ova' && $fmt ne 'ovf';

    # NOTE: all types of warnings must be added to the return schema of the import-metadata API endpoint
    my $warnings = [];

    my $isOva = 0;
    if ($fmt =~ m/^ova/) {
        $isOva = 1;
        push @$warnings, { type => 'ova-needs-extracting' };
    }
    my $path = $class->path($scfg, $volname, $storeid, undef);
    my $res = PVE::GuestImport::OVF::parse_ovf($path, $isOva);
    my $disks = {};
    for my $disk ($res->{disks}->@*) {
        my $id = $disk->{disk_address};
        my $size = $disk->{virtual_size};
        my $path = $disk->{relative_path};
        my $volid;
        if ($isOva) {
            $volid = "$storeid:$volname/$path";
        } else {
            $volid = "$storeid:import/$path",;
        }
        $disks->{$id} = {
            volid => $volid,
            defined($size) ? (size => $size) : (),
        };
    }

    if (defined($res->{qm}->{bios}) && $res->{qm}->{bios} eq 'ovmf') {
        $disks->{efidisk0} = 1;
        push @$warnings, { type => 'efi-state-lost', key => 'bios', value => 'ovmf' };
    }

    return {
        type => 'vm',
        source => $volname,
        'create-args' => $res->{qm},
        'disks' => $disks,
        warnings => $warnings,
        net => $res->{net},
    };
}

sub volume_qemu_snapshot_method {
    my ($class, $storeid, $scfg, $volname) = @_;

    my $format = ($class->parse_volname($volname))[6];
    return 'storage' if $format ne 'qcow2';

    return $scfg->{'snapshot-as-volume-chain'} ? 'mixed' : 'qemu';
}


# qemu_img_info() returns raw JSON text, so decode before use. Returns the backing
# filename, or undef when there is none / the image cannot be inspected.
my sub qcow2_backing_file {
    my ($path) = @_;
    my $json = eval { PVE::Storage::Common::qemu_img_info($path, undef, 10) };
    return undef if $@ || !$json;
    my $info = eval { decode_json($json) };
    return undef if $@ || ref($info) ne 'HASH';
    return $info->{'backing-filename'};
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    if ($feature eq 'copy-offload-atomic') {
        # reflink clones a whole file; there is no way to pick a snapshot out of one
        return 0 if $snapname;

        my ($vtype, undef, undef, undef, undef, undef, $format) =
            eval { $class->parse_volname($volname) };
        return 0 if $@ || !defined($vtype) || $vtype ne 'images';
        return 0 if $format ne 'raw' && $format ne 'qcow2';

        # A qcow2 with a backing file cannot be flattened by a byte-identical copy, so
        # do not advertise it -- otherwise the clone would fail in prepare instead of
        # quietly taking the normal host-side path.
        if ($format eq 'qcow2') {
            my $path = eval { $class->filesystem_path($scfg, $volname) };
            return 0 if $@ || !defined($path);
            return 0 if qcow2_backing_file($path);
        }

        return 1;
    }

    return $class->SUPER::volume_has_feature(
        $scfg, $feature, $storeid, $volname, $snapname, $running, $opts,
    );
}

# ---- storage-offloaded full copy via reflink -------------------------------------
#
# A filesystem that supports FICLONE (XFS with reflink=1, btrfs, ZFS with block
# cloning) can produce a full copy by sharing extents copy-on-write. Unlike an RBD
# clone or a ZFS clone-from-snapshot, the result is INDEPENDENT straight away: the
# extents are reference counted, so deleting the source does not affect the copy.
#
# That makes this the cheapest possible member of the 'copy-offload-atomic' class --
# instant, no extra space, and nothing to wait for. copy_image_status() reports
# 'complete' on the first poll because there is no background work.

# Same filesystem? FICLONE cannot cross one, and the caller may be copying between
# two different storages that happen to be directories.
my sub same_filesystem {
    my ($a, $b) = @_;
    my $da = (stat($a))[0];
    my $db = (stat($b))[0];
    return defined($da) && defined($db) && $da == $db;
}

sub copy_image_prepare {
    my (
        $class, $scfg, $storeid, $volname,
        $target_scfg, $target_storeid, $target_vmid, $snap, $opts,
    ) = @_;

    die "copy offload cannot copy from a snapshot\n" if defined($snap);

    my ($vtype, undef, undef, undef, undef, undef, $format) = $class->parse_volname($volname);
    die "copy offload only handles VM images, not '$vtype'\n" if $vtype ne 'images';

    # FICLONE copies bytes; it cannot convert between formats.
    my $target_format = $opts->{format} // $format;
    die "copy offload cannot convert '$format' to '$target_format'\n"
        if $target_format ne $format;

    my $path = $class->filesystem_path($scfg, $volname);

    # A qcow2 with a backing file is NOT independent, and a byte-identical copy of it
    # inherits that dependency -- it would pass qemu-img check and then break when the
    # base is removed. Only a real convert can flatten it.
    die "copy offload cannot flatten '$volname': it has a backing file\n"
        if $format eq 'qcow2' && qcow2_backing_file($path);

    my $target_dir = $class->get_subdir($target_scfg, 'images') . "/$target_vmid";
    mkpath $target_dir;

    die "copy offload requires source and target on the same filesystem\n"
        if !same_filesystem($path, $target_dir);

    # the trailing 1 adds the format suffix; without it the volname does not parse
    my $name =
        $class->find_free_diskname($target_storeid, $target_scfg, $target_vmid, $format, 1);

    # Reserve the name by creating the file. The caller drops the storage lock between
    # prepare and start, so a name that was merely chosen could be taken by a
    # concurrent allocation -- and the caller's rollback would then delete somebody
    # else's volume. An empty file costs nothing and makes the target freeable.
    my $target_path = "$target_dir/$name";
    my $fh = IO::File->new($target_path, O_WRONLY | O_CREAT | O_EXCL, 0640)
        or die "unable to reserve '$target_path' - $!\n";
    close($fh);

    return "$target_vmid/$name";
}

sub copy_image_start {
    my (
        $class, $scfg, $storeid, $volname,
        $target_scfg, $target_storeid, $target_volname, $snap,
    ) = @_;

    my $src = $class->filesystem_path($scfg, $volname);
    my $dst = $class->filesystem_path($target_scfg, $target_volname);

    # --reflink=always so an unsupported filesystem fails loudly rather than silently
    # turning this into a full byte copy that blocks the caller -- which may be holding
    # a guest frozen.
    eval { PVE::Tools::run_command(['/bin/cp', '--reflink=always', '--', $src, $dst]) };
    if (my $err = $@) {
        unlink($dst);
        die "reflink copy of '$volname' failed - $err";
    }

    return;
}

sub copy_image_status {
    my ($class, $scfg, $storeid, $volname, $source) = @_;

    # FICLONE is synchronous and the extents are reference counted, so the copy is
    # already independent of its source. Nothing to poll and nothing to clean up.
    return { state => 'complete' };
}


1;
