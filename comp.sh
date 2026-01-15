mkdir -p old
mv -f $1 old
/usr/local/bin/ocamlc -nopervasives $1.ml -o $1
/usr/local/bin/ocamlrund -t -t $1 > $1.trace
./$1
make obj_dir/Vocaml4142_vm
obj_dir/Vocaml4142_vm $1 $1.trace > $1.vtrace
echo `grep ^caml_ml_output_char $1.vtrace | cut -d\  -f2`
