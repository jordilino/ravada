package Ravada::Volume::QCOW2;

use Data::Dumper;
use Moose;

extends 'Ravada::Volume';
with 'Ravada::Volume::Class';

no warnings "experimental::signatures";
use feature qw(signatures);

has 'capacity' => (
    isa => 'Int'
    ,is => 'ro'
    ,lazy => 1
    ,builder => '_get_capacity'
);

our $QEMU_IMG = "/usr/bin/qemu-img";

sub prepare_base($self) {

    my $file_img = $self->file;
    my $base_img = $self->base_filename();
    confess $base_img if $base_img !~ /\.ro/;

    confess "Error: '$base_img' already exists" if -e $base_img;

    my @cmd = _cmd_convert($file_img,$base_img);

    my ($out, $err) = $self->vm->run_command( @cmd );
    warn $out  if $out;
    confess "$?: $err"   if $err;

    if (! $self->vm->file_exists($base_img)) {
        chomp $err;
        chomp $out;
        die "ERROR: Output file $base_img not created at "
        ."\n"
        ."ERROR: '".($err or '')."'\n"
        ."  OUT: '".($out or '')."'\n"
        ."\n"
        .join(" ",@cmd);
    }

    chmod 0555,$base_img;

    return $base_img;

}

sub clone($self, $file_clone) {
    my $n = 10;
    for (;;) {
        my @stat = stat($self->file);
        last if time-$stat[9] || $n--<0;
        sleep 1;
        die "Error: ".$self->file." looks active" if $n-- <0;
    }
    my @cmd = ($QEMU_IMG,'create'
        ,'-f','qcow2'
        ,'-F','qcow2'
        ,"-b", $self->file
        ,$file_clone
    );
    my ($out, $err) = $self->vm->run_command(@cmd);
    confess $err if $err;

    return $file_clone;
}

sub _get_capacity($self) {
    my @cmd = ($QEMU_IMG,"info", $self->file);
    my ($out, $err) = $self->vm->run_command(@cmd);

    confess $err if $err;
    my ($size) = $out =~ /virtual size: .*\((\d+) /ms;
    confess "I can't find size from $out" if !defined $size;

    return $size;
}

sub _cmd_convert($base_img, $qcow_img) {

    return    ($QEMU_IMG,'convert',
                '-O','qcow2', $base_img
                ,$qcow_img
        );

}

sub _cmd_copy {
    my ($base_img, $qcow_img) = @_;

    return ('/bin/cp'
            ,$base_img, $qcow_img
    );
}

sub backing_file($self) {
    my @cmd = ( $QEMU_IMG,'info',$self->file);

    my ($out, $err) = $self->vm->run_command(@cmd);
    die $err if $err;

    my ($base) = $out =~ m{^backing file: (.*)}mi;

    return $base;
}

sub rebase($self, $new_base) {
    my @cmd = ($QEMU_IMG,'rebase','-b',$new_base,$self->file);
    my ($out, $err) = $self->vm->run_command(@cmd);
    die $err if $err;

}

sub spinoff($self) {
    my $file = $self->file;
    my $volume_tmp  = $self->file.".$$.tmp";

    $self->vm->remove_file($volume_tmp);

    my @cmd = ($QEMU_IMG
        ,'convert'
        ,'-O','qcow2'
        ,$file
        ,$volume_tmp
    );
    my ($out, $err) = $self->vm->run_command(@cmd);
    warn $out  if $out;
    warn $err   if $err;
    confess "ERROR: Temporary output file $volume_tmp not created at "
    .join(" ",@cmd)
    .($out or '')
    .($err or '')
    ."\n"
    if (! $self->vm->file_exists($volume_tmp) );

    $self->copy_file($volume_tmp,$file) or die "$! $volume_tmp -> $file";
    $self->vm->remove_file($volume_tmp) or die "ERROR $! removing $volume_tmp";
}

sub block_commit($self) {
    my @cmd = ($QEMU_IMG,'commit','-q','-d');
    my ($out, $err) = $self->vm->run_command(@cmd, $self->file);
    warn $err   if $err;
}
1;
