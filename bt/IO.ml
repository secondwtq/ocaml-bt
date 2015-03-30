(* The MIT License (MIT)

   Copyright (c) 2014 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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

let (>>=) = Lwt.(>>=)

type t = {
  mutable fd : Lwt_unix.file_descr;
  on_write : unit Lwt_condition.t;
  mutable enc : Cryptokit.Stream.stream_cipher option;
  mutable dec : Cryptokit.Stream.stream_cipher option;
  addr : Addr.t
}

let close_raw sock =
  Lwt_unix.close sock.fd

let read_raw sock str pos len =
  Lwt_unix.read sock.fd str pos len

let write_raw sock str pos len =
  Lwt_unix.write sock.fd str pos len >>= fun n ->
  Lwt_condition.broadcast sock.on_write ();
  Lwt.return n

let read sock str pos len =
  match sock.dec with
  | None ->
    read_raw sock str pos len
  | Some c ->
    let buf = String.create len in
    read_raw sock buf 0 len >>= fun n ->
    c#transform buf 0 str pos n;
    Lwt.return n

let really_write_raw sock str pos len =
  let rec loop pos len =
    if len <= 0 then
      Lwt.return ()
    else
      write_raw sock str pos len >>= fun n ->
      loop (pos + n) (len - n)
  in
  loop pos len

let write sock str pos len =
  match sock.enc with
  | None ->
    write_raw sock str pos len
  | Some c ->
    let buf = String.create len in
    c#transform str pos buf 0 len;
    really_write_raw sock buf 0 len >>= fun () ->
    Lwt.return len

let close sock =
  begin match sock.enc with Some c -> c#wipe | _ -> () end;
  begin match sock.dec with Some c -> c#wipe | _ -> () end;
  close_raw sock

let really_read sock str pos len =
  let rec loop pos len =
    if len <= 0 then
      Lwt.return ()
    else
      read sock str pos len >>= function
      | 0 -> Lwt.fail End_of_file
      | n -> loop (pos + n) (len - n)
  in
  loop pos len

let read_char sock =
  let buf = String.create 1 in
  really_read sock buf 0 1 >>= fun () ->
  Lwt.return buf.[0]

let read_string sock len =
  let str = String.create len in
  really_read sock str 0 len >>= fun () ->
  Lwt.return str

let read_int16 sock =
  read_string sock 2 >>= fun s ->
  bitmatch Bitstring.bitstring_of_string s with
  | { n : 16 } -> Lwt.return n

let read_int32 sock =
  read_string sock 4 >>= fun s ->
  bitmatch Bitstring.bitstring_of_string s with
  | { n : 32 } -> Lwt.return n

let really_write sock str pos len =
  let rec loop pos len =
    if len <= 0 then
      Lwt.return ()
    else
      write sock str pos len >>= fun n ->
      loop (pos + n) (len - n)
  in
  loop pos len

let write_string sock str =
  really_write sock str 0 (String.length str)

let write_bitstring sock (s, ofs, len) =
  assert (ofs land 7 = 0 && len land 7 = 0);
  really_write sock s (ofs lsr 3) (len lsr 3)

let write_int16 sock n =
  write_bitstring sock (BITSTRING { n :  16 })

let write_int32 sock n =
  write_bitstring sock (BITSTRING { n : 32 })

let on_write sock =
  Lwt_condition.wait sock.on_write

let enable_encryption sock c =
  match sock.enc with
  | None -> sock.enc <- Some c
  | Some _ -> assert false

let disable_encryption sock =
  match sock.enc with
  | None -> assert false
  | Some _ -> sock.enc <- None

let enable_decryption sock c =
  match sock.dec with
  | None -> sock.dec <- Some c
  | Some _ -> assert false

let disable_decryption sock =
  match sock.dec with
  | Some _ -> sock.dec <- None
  | None -> assert false

let is_encrypted sock =
  match sock.enc, sock.dec with
  | None, None -> false
  | Some _, _
  | _, Some _ -> true

let create addr =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  { on_write = Lwt_condition.create ();
    enc = None;
    dec = None;
    addr;
    fd }

let of_file_descr fd =
  { on_write = Lwt_condition.create ();
    enc = None;
    dec = None;
    addr = Addr.of_sockaddr (Lwt_unix.getpeername fd);
    fd }

let connect sock =
  Lwt_unix.connect sock.fd (Addr.to_sockaddr sock.addr)

let reconnect sock =
  sock.enc <- None;
  sock.dec <- None;
  Lwt_unix.close sock.fd >>= fun () ->
  sock.fd <- Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0;
  Lwt_unix.connect sock.fd (Addr.to_sockaddr sock.addr)

let addr sock =
  sock.addr

let default_buffer_size = 32 * 1024

let out_channel ?(buffer_size = default_buffer_size) sock =
  let write_bytes b ofs len =
    let str = String.create len in
    Lwt_bytes.blit_to_bytes b ofs str 0 len;
    really_write sock str 0 len >>= fun () ->
    Lwt.return len
  in
  Lwt_io.make ~buffer_size
    ~mode:Lwt_io.Output
    ~close:(fun () -> close sock)
    write_bytes

let in_channel ?(buffer_size = default_buffer_size) sock =
  let read_bytes b ofs len =
    let str = String.create len in
    read sock str 0 len >>= fun n ->
    Lwt_bytes.blit_from_bytes str 0 b ofs n;
    Lwt.return n
  in
  Lwt_io.make ~buffer_size
    ~mode:Lwt_io.Input
    ~close:(fun () -> close sock)
    read_bytes
