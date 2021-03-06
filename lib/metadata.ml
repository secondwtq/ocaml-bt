(* The MIT License (MIT)

   Copyright (c) 2013-2015 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
   FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
   COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
   IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. *)

type file_info =
  { file_path     : string list;
    file_size     : int64 }

type t =
  { name : string;
    info_hash : SHA1.t;
    hashes : SHA1.t array;
    piece_length : int;
    last_piece_size : int;
    total_length : int64;
    files : file_info list;
    encoded : Cstruct.t }

let length info =
  Cstruct.len info.encoded

let piece_size = 16 * 1024 (* bytes *)
let block_size = 16 * 1024

let get_piece info i =
  let l = Cstruct.len info.encoded in
  let numpieces = (l + piece_size - 1) / piece_size in
  if i >= numpieces || i < 0 then invalid_arg "Info.get_piece";
  if i < numpieces - 1 then
    Cstruct.sub info.encoded (i * piece_size) piece_size
  else
    let last_piece_size = l mod piece_size in
    let last_piece_size = if last_piece_size = 0 then piece_size else last_piece_size in
    Cstruct.sub info.encoded (i * piece_size) last_piece_size

(* let comment bc = *)
(*   try Some (Bcode.find "comment" bc |> Bcode.to_string) *)
(*   with Not_found -> None *)

(* let creation_date bc = *)
(*   Bcode.search_string "creation date" bc *)

let either f g x =
  try f x with _ -> g x

(* let announce_list bc = *)
(*   let announce_list () = *)
(*     Bcode.find "announce-list" bc |> Bcode.to_list |> *)
(*     List.map (fun l -> *)
(*         Bcode.to_list l |> List.map (fun s -> Bcode.to_string s |> Uri.of_string)) *)
(*   in *)
(*   let announce () = *)
(*     let announce = Bcode.find "announce" bc |> Bcode.to_string in *)
(*     [[Uri.of_string announce]] *)
(*   in *)
(** announce_list takes precedence over announce - see BEP 12 *)
(*   either announce_list announce () *)

let split_at n cs =
  let l = Cstruct.len cs in
  if l mod n <> 0 then invalid_arg "Metadata.split_at";
  Array.init (l / n) (fun i -> Cstruct.sub cs (n * i) n)

let hashes bc =
  Bcode.find "pieces" bc |> Bcode.to_cstruct |> split_at 20 |> Array.map SHA1.of_raw

let info_hash (bc : Bcode.t) =
  SHA1.digest (Bcode.encode bc)

let piece_length bc =
  Bcode.find "piece length" bc |> Bcode.to_int

let name bc =
  Bcode.find "name" bc |> Bcode.to_string

let files bc =
  let name = Bcode.find "name" bc |> Bcode.to_string in
  let many_files () =
    Bcode.find "files" bc |> Bcode.to_list |>
    List.map (fun d ->
      let file_size = Bcode.find "length" d |> Bcode.to_int64 in
      let path = Bcode.find "path" d |> Bcode.to_list |> List.map Bcode.to_string in
      {file_size; file_path = name :: path})
  in
  let single_file () =
    let n = Bcode.find "length" bc |> Bcode.to_int64 in
    [{file_size = n; file_path = [name]}]
  in
  either many_files single_file ()

let total_length (bc : Bcode.t) =
  let many_files () =
    Bcode.find "files" bc |> Bcode.to_list |>
    List.fold_left (fun acc d -> Bcode.find "length" d |> Bcode.to_int64 |> Int64.add acc) 0L
  in
  let single_file () =
    Bcode.find "length" bc |> Bcode.to_int64
  in
  either single_file many_files ()

open Format

let rec pp_announce_list fmt xs =
  let rec loop fmt = function
    | [] -> ()
    | [x] -> fprintf fmt "[@[<hov 2>%a@]]" pp_tier x
    | x :: xs -> fprintf fmt "[@[<hov 2>%a@]]@,%a" pp_tier x loop xs
  in loop fmt xs

and pp_tier fmt = function
  | [] -> ()
  | [x] -> fprintf fmt "%s" (Uri.to_string x)
  | x :: xs -> fprintf fmt "%s;@ %a" (Uri.to_string x) pp_tier xs

let create bc =
  let name = name bc in
  let hashes = hashes bc in
  let info_hash = info_hash bc in
  let piece_length = piece_length bc in
  let total_length = total_length bc in
  let files = files bc in
  let last_piece_size = Int64.to_int (Int64.rem total_length (Int64.of_int piece_length)) in
  let last_piece_size = if last_piece_size = 0 then piece_length else last_piece_size in
  { name; info_hash; piece_length; total_length; last_piece_size;
    hashes; files; encoded = Bcode.encode bc }

let total_length m =
  m.total_length

let piece_count m =
  Array.length m.hashes

let piece_length m i =
  if i < 0 || i >= Array.length m.hashes then invalid_arg "Metadata.piece_length";
  if i = Array.length m.hashes - 1 then m.last_piece_size else m.piece_length

let offset m i off =
  Int64.(add (mul (of_int i) (of_int m.piece_length)) (of_int off))

let print oc info =
  Printf.fprintf oc "             name: %s\n" info.name;
  Printf.fprintf oc "        info hash: %a\n" SHA1.print_hex info.info_hash;
  (* Format.fprintf fmt "    announce-list: @[<v>%a@]@," pp_announce_list announce_list; *)
  Printf.fprintf oc "     total length: %s\n" (Util.string_of_file_size info.total_length);
  Printf.fprintf oc "     piece length: %s\n" (Util.string_of_file_size (Int64.of_int info.piece_length));
  Printf.fprintf oc " number of pieces: %d\n" (Array.length info.hashes);
  let rec loop i = function
    | [] -> ()
    | fi :: files ->
  Printf.fprintf oc "          file %d: %s (%s)\n" i (String.concat "/" fi.file_path)
    (Util.string_of_file_size fi.file_size);
  loop (i+1) files
  in
  loop 0 info.files;
  flush oc

let block_count meta i =
  let len = piece_length meta i in
  (len + block_size - 1) / block_size

let hash m i =
  m.hashes.(i)

let files m =
  List.map (fun fi -> fi.file_path, fi.file_size) m.files
