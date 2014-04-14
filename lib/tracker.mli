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

type event =
  | STARTED
  | STOPPED
  | COMPLETED

exception Error of string
exception Warning of string

type response = {
  peers : Addr.t list;
  leechers : int option;
  seeders : int option;
  interval : int
}

val query :
  Uri.t ->
  Word160.t ->
  ?up:int64 ->
  ?down:int64 ->
  ?left:int64 ->
  ?event:event ->
  int ->
  Word160.t -> response Lwt.t

module Tier : sig
  type t

  exception No_valid_tracker

  val create : unit -> t
  val shuffle : t -> unit
  val add_tracker : t -> Uri.t -> unit
  val query : t -> Word160.t -> ?up:int64 -> ?down:int64 -> ?left:int64 -> ?event:event ->
    int -> Word160.t -> response Lwt.t
  val show : t -> string
end
