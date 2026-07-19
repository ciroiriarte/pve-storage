package PVE::Storage::TestCopyOffload;

use strict;
use warnings;

use lib qw(..);

use PVE::Storage;
use Test::More;

# copy_offload_class() decides whether a full copy may be handed to the backend, and
# which of the two classes to use. Getting it wrong either silently declines an offload
# or drives one onto a storage pair that cannot perform it, so the rules are pinned here.
#
# The checks are: the TARGET storage must have copy-offload enabled, both storages must
# be instances of the same plugin type, and the plugin must advertise a class for that
# volume. 'atomic' wins when a plugin advertises both, as it needs no host-side mirror.

my $features = {}; # volid => { feature => 1 }

{
    no warnings 'redefine';
    *PVE::Storage::volume_has_feature = sub {
        my ($cfg, $feature, $volid, $snap, $running, $opts) = @_;
        return $features->{$volid}->{$feature} ? 1 : 0;
    };
}

my $cfg = {
    ids => {
        'rbd-a' => { type => 'rbd', 'copy-offload' => 1 },
        'rbd-b' => { type => 'rbd', 'copy-offload' => 1 },
        'rbd-off' => { type => 'rbd' },
        'dir-a' => { type => 'dir', 'copy-offload' => 1 },
    },
};

my $volid = 'rbd-a:vm-100-disk-0';

my $tests = [
    # [ description, target storeid, advertised features, expected class ]
    ['nothing advertised => no offload', 'rbd-b', {}, undef],
    ['atomic advertised', 'rbd-b', { 'copy-offload-atomic' => 1 }, 'atomic'],
    ['bulk advertised', 'rbd-b', { 'copy-offload-bulk' => 1 }, 'bulk'],
    [
        'atomic preferred when both are advertised',
        'rbd-b',
        { 'copy-offload-atomic' => 1, 'copy-offload-bulk' => 1 },
        'atomic',
    ],
    [
        'target has copy-offload disabled',
        'rbd-off',
        { 'copy-offload-atomic' => 1 },
        undef,
    ],
    [
        'cross-type is out of scope even when advertised',
        'dir-a',
        { 'copy-offload-atomic' => 1 },
        undef,
    ],
    [
        'same storage as source is allowed',
        'rbd-a',
        { 'copy-offload-atomic' => 1 },
        'atomic',
    ],
];

plan tests => scalar(@$tests) + 1;

for my $t (@$tests) {
    my ($desc, $target, $adv, $expected) = @$t;

    $features = { $volid => $adv };

    my $got = PVE::Storage::copy_offload_class($cfg, $volid, $target, undef, 0);
    is($got, $expected, $desc);
}

# A path that is not a storage volume must not be mistaken for an offloadable one.
$features = { $volid => { 'copy-offload-atomic' => 1 } };
is(
    PVE::Storage::copy_offload_class($cfg, '/dev/sdb', 'rbd-b', undef, 0),
    undef,
    'a bare path is never offloadable',
);

done_testing();
