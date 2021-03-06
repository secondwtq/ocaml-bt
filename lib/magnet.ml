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

module Log = Log.Make (struct let section = "Magnet" end)

type t =
  { xt : SHA1.t;
    dn : string option;
    tr : Uri.t list }

let string_split (str : string) (delim : char) : string list =
  let rec loop start len =
    if start+len >= String.length str then
      [String.sub str start len]
    else if str.[start+len] = delim then
      String.sub str start len :: loop (start+len+1) 0
    else
      loop start (len+1)
  in
  loop 0 0

let split_two delim s =
  let i = String.index s delim in
  String.sub s 0 i, String.sub s (i+1) ((String.length s)-i-1)

let parse s =
  let s = Scanf.sscanf s "magnet:?%s" (fun s -> s) in
  let comps = string_split s '&' |> List.map (split_two '=') in
  let rec loop xt dn tr = function
    | [] ->
        begin match xt with
        | None ->
            failwith "Magnet.parse: no 'xt' component"
        | Some xt ->
            { xt; dn; tr = List.rev tr }
        end
    | ("xt", xt) :: rest ->
        let xt =
          try
            Scanf.sscanf xt "urn:btih:%s" SHA1.of_hex
          with
          | _ ->
              Scanf.sscanf xt "urn:sah1:%S" SHA1.of_base32
        in
        loop (Some xt) dn tr rest
    | ("dn", dn) :: rest ->
        loop xt (Some dn) tr rest
    | ("tr", uri) :: rest ->
        loop xt dn (Uri.of_string (Uri.pct_decode uri) :: tr) rest
    | _ :: rest ->
        (* Printf.eprintf "ignoring %S\n%!" n; *)
        loop xt dn tr rest
  in
  loop None None [] comps

let parse s =
  Log.debug "parsing %S" s;
  try
    let m = parse s in
    Log.debug "  xt = %a" SHA1.print_hex m.xt;
    (match m.dn with Some dn -> Log.debug "  dn = %S" dn | None -> ());
    List.iter (fun tr -> Log.debug "  tr = %s" (Uri.to_string tr)) m.tr;
    `Ok m
  with e ->
    Log.error "parsing failed: %S" (Printexc.to_string e);
    `Error
