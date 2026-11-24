#!/usr/bin/env perl
# Tradução de caminho do File Restore (base64 → drive/part/subpasta),
# buckets recusados, path traversal, parse de volid.
use strict;
use warnings;
use utf8;
use lib 't/restore';
use RestoreTest qw(b64);

use MIME::Base64 qw(encode_base64);
use Test::More;

BEGIN { use_ok('MMPve::Module::Restore') }

my $R = 'MMPve::Module::Restore';

# ---- parse_volid
my %v = $R->parse_volid('pbs1:backup/vm/100/2026-10-26T02:00:03Z');
is($v{storage}, 'pbs1', 'volid storage');
is($v{vmid}, 100, 'volid vmid');
is($v{timestamp}, '2026-10-26T02:00:03Z', 'volid ts');
eval { $R->parse_volid('lixo') };
like($@, qr/invalid volid/, 'invalid volid refused');

# ---- tradução válida completa
my $t = $R->translate_path(b64('/drive-scsi1.img.fidx/part/2/Dados/Financeiro'));
is($t->{drive}, 'drive-scsi1.img', 'drive');
is($t->{part}, 2, 'particao');
is($t->{subpath}, 'Dados/Financeiro', 'subpasta');

# sem partição (disco inteiro? — vira subpasta vazia)
$t = $R->translate_path(b64('/drive-sata0.img.fidx'));
is($t->{drive}, 'drive-sata0.img', 'drive sem part');
is($t->{part}, undef, 'sem particao');
is($t->{subpath}, '', 'subpasta vazia');

# aceita caminho já decodificado (uso interno)
$t = $R->translate_path('/drive-scsi1.img.fidx/part/1');
is($t->{part}, 1, 'particao via caminho plano');

# ---- buckets recusados (fase 2)
for my $p ('/drive-scsi1.img.fidx/lvm/data', '/drive-scsi1.img.fidx/part/1/zpool',
    '/drive-scsi0.img.fidx/raw') {
    eval { $R->translate_path(b64($p)) };
    like($@, qr/bucket .*phase 2/, "bucket refused: $p");
}

# ---- path traversal / lixo
for my $p ('/../etc', '/drive-scsi1.img.fidx/part/2/../../etc',
    '/drive-scsi1.img.fidx/part/2/../../..') {
    eval { $R->translate_path(b64($p)) };
    like($@, qr/\.\.|caracteres/, "traversal recusado: $p");
}
eval { $R->translate_path(encode_base64("/drive-scsi1.img.fidx/part/2/x\0y")) };
like($@, qr/invalid base64|control characters/, 'null byte refused');

# primeiro componente precisa ser drive-*.fidx
eval { $R->translate_path(b64('/notes.txt')) };
like($@, qr/drive-\*\.img\.fidx/, 'arquivo solto recusado');

# part fora da faixa
eval { $R->translate_path(b64('/drive-scsi1.img.fidx/part/0')) };
like($@, qr/partition must be 1/, 'partition 0 refused');

# caminho sem barra
eval { $R->translate_path(b64('drive-scsi1.img.fidx')) };
like($@, qr/path must start with/, 'missing leading slash refused');

# ---- publicar exige uma pasta dentro de uma partição (contrato v1)
ok(eval { $R->require_folder($R->translate_path(b64('/drive-sata1.img.fidx/part/2/Área de Trabalho'))) },
    'pasta dentro da partição é aceita') or diag $@;
for my $p ('/drive-sata1.img.fidx/part/2', '/drive-sata1.img.fidx/part/2/', '/drive-sata0.img.fidx') {
    eval { $R->require_folder($R->translate_path(b64($p))) };
    like($@, qr/choose a folder inside the partition/, "refused without folder: $p");
}

done_testing();
