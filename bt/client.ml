(* The MIT License (MIT)

   Copyright (c) 2015 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

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

module ARC4 = Nocrypto.Cipher_stream.ARC4

let section = Log.make_section "Client"

let debug ?exn fmt = Log.debug section ?exn fmt

let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)

let listen_ports = [50000]

open Event

type t = {
  id : SHA1.t;
  ih : SHA1.t;
  mutable trackers : Tracker.Tier.t list;
  peer_mgr : PeerMgr.swarm;
  chan : event Lwt_stream.t;
  push : event -> unit;
  (* listener : Listener.t; *)
  dht : DHT.t
}

(* let get_next_requests bt p n = *)
(*   match bt.stage with *)
(*   | HasMeta (_, Leeching (_, _, r)) -> *)
(*       (\* if not (Peer.peer_choking p) then *\)Requester.get_next_requests r p n *)
(*   (\* else [] *\) *)
(*   | HasMeta _ -> [] *)
(*   | NoMeta _ -> [] *)

(* let get_next_metadata_request bt p = *)
(*   match bt.stage with *)
(*   | NoMeta (PartialMeta m) -> *)
(*       IncompleteMetadata.get_next_metadata_request m *)
(*   | _ -> *)
(*       None *)

module Cs = Nocrypto.Uncommon.Cs

let proto = Cstruct.of_string "\019BitTorrent protocol"

let extensions =
  let bits = Bits.create (8 * 8) in
  Bits.set bits Wire.ltep_bit;
  Bits.set bits Wire.dht_bit;
  Cstruct.of_string @@ Bits.to_bin bits

let handshake_len = Cstruct.len proto + 8 (* extensions *) + 20 (* info_hash *) + 20 (* peer_id *)

let handshake_message peer_id info_hash =
  Cs.concat [ proto; extensions; SHA1.to_raw info_hash; SHA1.to_raw peer_id ]

let parse_handshake cs =
  assert (Cstruct.len cs = handshake_len);
  match Cstruct.get_uint8 cs 0 with
  | 19 ->
      let proto' = Cstruct.sub cs 0 20 in
      if Cs.equal proto' proto then
        let ext = Cstruct.sub cs 20 8 in
        let info_hash = Cstruct.sub cs 28 20 in
        let peer_id = Cstruct.sub cs 48 20 in
        (ext, SHA1.of_raw info_hash, SHA1.of_raw peer_id)
      else
        failwith "bad proto"
  | _ ->
      failwith "bad proto length"

let buf_size = 1024

let encrypt mode cs =
  match mode with
  | `Plain -> `Plain, cs
  | `Encrypted (my_key, her_key) ->
      let { ARC4.key = my_key; message = cs } = ARC4.encrypt ~key:my_key cs in
      `Encrypted (my_key, her_key), cs

let decrypt mode cs =
  match mode with
  | `Plain -> `Plain, cs
  | `Encrypted (my_key, her_key) ->
      let { ARC4.key = my_key; message = cs } = ARC4.decrypt ~key:her_key cs in
      `Encrypted (my_key, her_key), cs

let negotiate fd t =
  let read_buf = Cstruct.create buf_size in
  let rec loop = function
    | `Ok (t, Some cs) ->
        Lwt_cstruct.complete (Lwt_cstruct.write fd) cs >>= fun () ->
        loop (Handshake.handle t Cs.empty)
    | `Ok (t, None) ->
        Lwt_cstruct.read fd read_buf >>= begin function
        | 0 ->
            failwith "eof"
        | n ->
            loop (Handshake.handle t (Cstruct.sub read_buf 0 n))
        end
    | `Error err ->
        failwith err
    | `Success (mode, rest) ->
        Lwt.return (`Ok (mode, rest))
  in
  loop t

let connect_to_peer info_hash ip port timeout =
  let my_id = SHA1.generate () in (* FIXME FIXME *)
  let fd = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
  Lwt_unix.gethostbyaddr ip >>= fun he ->
  let sa = Lwt_unix.ADDR_INET (he.Lwt_unix.h_addr_list.(0), port) in
  Lwt_unix.connect fd sa >>= fun () ->
  negotiate fd Handshake.(outgoing ~info_hash Both) >>= function
  | `Ok (mode, rest) ->
      Lwt_cstruct.complete (Lwt_cstruct.write fd) (handshake_message info_hash my_id) >>= fun () ->
      assert (Cstruct.len rest <= handshake_len);
      let n = handshake_len - Cstruct.len rest in
      let hs = Cstruct.create handshake_len in
      Cstruct.blit rest 0 hs 0 (Cstruct.len rest);
      Lwt_cstruct.complete (Lwt_cstruct.read fd) (Cstruct.shift hs (Cstruct.len rest)) >>= fun () ->
      let ext, info_hash', peer_id = parse_handshake hs in
      assert (SHA1.equal info_hash info_hash');
      Lwt.return (mode, fd, ext, peer_id)
  | `Error _ ->
      assert false

let connect_to_peer info_hash push ((ip, port) as addr) timeout =
  Lwt.try_bind
    (fun () -> connect_to_peer info_hash ip port timeout)
    (fun (mode, fd, ext, peer_id) ->
       Lwt.wrap1 push @@ PeerConnected (mode, fd, Bits.of_bin (Cstruct.to_string ext), peer_id))
    (fun _ -> Lwt.wrap1 push @@ ConnectFailed addr)

let buf_size = 1024

let reader_loop push fd p =
  let buf = Cstruct.create buf_size in
  let rec loop r =
    Lwt_unix.with_timeout (float Peer.keepalive_delay)
      (fun () -> Lwt_cstruct.read fd buf) >>= function
    | 0 ->
        failwith "eof"
    | n ->
        let r, msgs = Wire.R.handle r (Cstruct.sub buf 0 n) in
        List.iter (fun msg -> push (Peer.got_message p msg)) msgs;
        loop r
  in
  Lwt.catch
    (fun () -> loop Wire.R.empty)
    (fun e ->
       Printf.eprintf "unexpected exc: %S\n%!" (Printexc.to_string e);
       push (PeerDisconnected (Peer.id p));
       Lwt_unix.close fd >>= fun () ->
       Lwt.return_unit)

  (*   Lwt.pick *)
  (*     [(Lwt_stream.next input >|= fun x -> `Ok x); *)
  (*      (\* (Lwt_condition.wait p.on_stop >|= fun () -> `Stop); *\) *)
  (*      (Lwt_unix.sleep (float Peer.keepalive_delay) >|= fun () -> `Timeout)] *)
  (*   >>= function *)
  (*   | `Ok x -> *)
  (*       begin match f x with *)
  (*       | None -> *)
  (*           loop f *)
  (*       | Some e -> *)
  (*           bt.push e; *)
  (*           loop f *)
  (*       end *)
  (*   (\* | `Stop -> Lwt.return () *\) *)
  (*   | `Timeout -> Lwt.fail Peer.Timeout *)
  (* in *)
  (* loop (Peer.got_message p) *)

(* let handle_torrent_event bt = function *)
(*   | Torrent.TorrentComplete -> *)
(*       debug "torrent completed!"; *)
(*       begin match bt.stage with *)
(*       | HasMeta (meta, Leeching (t, ch, _)) -> *)
(*           (\* FIXME stop requester ? *\) *)
(*           bt.stage <- HasMeta (meta, Seeding (t, ch)) *)
(*       | _ -> *)
(*           () *)
(*       end *)

  (* | TorrentLoaded dl -> *)
  (*         (\* debug "torrent loaded (good=%d,total=%d)" *\) *)
  (*         (\*   (Torrent.numgot dl) (Metadata.piece_count meta - Torrent.numgot dl); *\) *)
  (*         (\* PeerMgr.torrent_loaded bt.peer_mgr meta dl (get_next_requests bt); FIXME FIXME *\) *)
  (*         let ch = Choker.create bt.peer_mgr dl in *)
  (*         if Torrent.is_complete dl then *)
  (*           bt.stage <- HasMeta (meta, Seeding (dl, ch)) *)
  (*         else begin *)
  (*           let r = Requester.create meta dl in *)
  (*           bt.stage <- HasMeta (meta, Leeching (dl, ch, r)); *)
  (*           PeerMgr.iter_peers (fun p -> Requester.got_bitfield r (Peer.have p)) bt.peer_mgr *)
  (*         end; *)
  (*         Choker.start ch *)
(*     end *)

module Peers = Map.Make (SHA1)

let am_choking peers id =
  try
    let p = Peers.find id peers in
    Peer.am_choking p
  with
  | Not_found -> true

let peer_interested peers id =
  try
    let p = Peers.find id peers in
    Peer.peer_interested p
  with
  | Not_found -> false

let share_torrent bt meta dl peers =
  let ch = Choker.create bt.peer_mgr dl in
  let r = Requester.create meta dl in
  Peers.iter (fun _ p -> Requester.got_bitfield r (Peer.have p)) peers;
  (* PeerMgr.iter_peers (fun p -> Requester.got_bitfield r (Peer.have p)) bt.peer_mgr; *)
  Choker.start ch;
  let rec loop peers =
    Lwt_stream.next bt.chan >>= function
    | PeersReceived addrs ->
        debug "received %d peers" (List.length addrs);
        List.iter (fun addr -> bt.push (PeerMgr.add bt.peer_mgr addr)) addrs;
        loop peers

    | Announce (tier, event) ->
        let doit () =
          (* FIXME port *)
          Tracker.Tier.query tier ~ih:bt.ih ?up:None ?down:None ?left:None ?event ?port:None
            (* ?port:(Listener.port bt.listener) FIXME FIXME *) ~id:bt.id >>= fun resp ->
          debug "announce to %s successful, reannouncing in %ds"
            (Tracker.Tier.to_string tier) resp.Tracker.interval;
          bt.push (PeersReceived resp.Tracker.peers);
          Lwt_unix.sleep (float resp.Tracker.interval) >|= fun () ->
          bt.push (Announce (tier, None))
        in
        let safe_doit () =
          Lwt.catch doit (fun exn -> debug ~exn "announce failure"; Lwt.return ())
        in
        Lwt.async safe_doit;
        loop peers

    | PieceVerified i ->
        debug "piece %d verified and written to disk" i;
        (* PeerMgr.got_piece bt.peer_mgr i; *)
        Requester.got_piece r i;
        loop peers

    | PieceFailed i ->
        (* Announcer.add_bytes *)
        debug "piece %d failed hashcheck" i;
        Requester.got_bad_piece r i;
        (* PeerMgr.got_bad_piece bt.peer_mgr i; *)
        loop peers

    | HandshakeFailed addr ->
        bt.push (PeerMgr.handshake_failed bt.peer_mgr addr);
        loop peers

    | PeerDisconnected id ->
        bt.push (PeerMgr.peer_disconnected bt.peer_mgr id);
        if not (am_choking peers id) && peer_interested peers id then Choker.rechoke ch;
        (* Requester.peer_declined_all_requests r id; FIXME FIXME *)
        (* Requester.lost_bitfield r (Peer.have p); FIXME FIXME *)
        loop peers

    | AvailableMetadata _ ->
        loop peers

    | Choked p ->
        (* Requester.peer_declined_all_requests r p; FIXME FIXME *)
        loop peers

    | Interested id
    | NotInterested id ->
        if not (am_choking peers id) then Choker.rechoke ch;
        loop peers

    | Have (p, i) ->
        Requester.got_have r i;
        loop peers

    | HaveBitfield (p, b) ->
        Requester.got_bitfield r b;
        loop peers

    | MetaRequested (p, i) ->
        (* Peer.send_meta_piece p i (Metadata.length meta, Metadata.get_piece meta i); *)
        (* FIXME FIXME *)
        loop peers

    | GotMetaPiece _
    | RejectMetaPiece _ ->
        loop peers

    | BlockRequested (p, idx, b) ->
        (* if Torrent.has_piece dl idx then begin *)
        (*   let aux _ = Torrent.get_block dl idx b >|= Peer.send_block p idx b in *)
        (*   Lwt.async aux *)
        (* end; *)
        (* FIXME FIXME *)
        loop peers

    | BlockReceived (p, idx, b, s) ->
        (* FIXME *)
        (* debug "got block %d/%d (piece %d) from %s" b *)
        (*   (Metadata.block_count meta idx) idx (Peer.to_string p); *)
        (* (Util.string_of_file_size (Int64.of_float (Peer.download_rate p))); *)
        (* Requester.got_block r p idx b; *)
        (* Torrent.got_block t p idx b s; *)
        (* FIXME FIXME *)
        loop peers

    | GotPEX (p, added, dropped) ->
        (* debug "got pex from %s added %d dropped %d" (Peer.to_string p) *)
        (*   (List.length added) (List.length dropped); *)
        List.iter (fun (addr, _) -> bt.push (PeerMgr.add bt.peer_mgr addr)) added;
        loop peers

    | DHTPort (p, i) ->
        (* debug "got dht port %d from %s" i (Peer.to_string p); *)
        (* let addr, _ = Peer.addr p in *)
        (* Lwt.async begin fun () -> *)
        (*   DHT.ping bt.dht (addr, i) >|= function *)
        (*   | Some (id, addr) -> *)
        (*       DHT.update bt.dht Kademlia.Good id addr *)
        (*   | None -> *)
        (*       debug "%s did not reply to dht ping on port %d" (Peer.to_string p) i *)
        (* end; *)
        (* FIXME *)
        loop peers

    | PeerConnected (mode, sock, exts, id) ->
        let p =
          Peer.create_has_meta id bt.push meta (Requester.get_next_requests r)
        in
        Lwt.async (fun () -> reader_loop bt.push sock p);
        Peer.start p;
        (* Hashtbl.add bt.peers addr !!p; FIXME XXX *)
        if Bits.is_set exts Wire.ltep_bit then Peer.send_extended_handshake p;
        if Bits.is_set exts Wire.dht_bit then Peer.send_port p 6881; (* FIXME fixed port *)
        (* Peer.send_have_bitfield p (Torrent.have tor) *)
        (* FIXME *)
        loop peers
  in
  loop peers

let load_torrent bt meta =
  Torrent.create meta bt.push (* >|= fun dl -> *)
  (* bt.push (TorrentLoaded dl) *)

let rec fetch_metadata bt =
  let rec loop peers m =
    Lwt_stream.next bt.chan >>= function
    | AvailableMetadata (p, len) ->
        (* debug "%s offered %d bytes of metadata" (Peer.to_string p) len; *)
        (* FIXME *)
        begin match m with
        | None ->
            let m = IncompleteMetadata.create bt.ih len in
            loop peers (Some m)
        | _ ->
            loop peers m
        end

    | PeersReceived addrs ->
        debug "received %d peers" (List.length addrs);
        List.iter (fun addr -> bt.push (PeerMgr.add bt.peer_mgr addr)) addrs;
        loop peers m

    | Announce (tier, event) ->
        let doit () =
          (* FIXME port *)
          Tracker.Tier.query tier ~ih:bt.ih ?up:None ?down:None ?left:None ?event ?port:None (* FIXME FIXME (Listener.port bt.listener) *) ~id:bt.id >>= fun resp ->
          debug "announce to %s successful, reannouncing in %ds"
            (Tracker.Tier.to_string tier) resp.Tracker.interval;
          bt.push (PeersReceived resp.Tracker.peers);
          Lwt_unix.sleep (float resp.Tracker.interval) >|= fun () ->
          bt.push (Announce (tier, None))
        in
        let safe_doit () =
          Lwt.catch doit (fun exn -> debug ~exn "announce failure"; Lwt.return ())
        in
        Lwt.async safe_doit;
        loop peers m

    | PeerConnected (mode, sock, exts, id) ->
        let p = Peer.create_no_meta id bt.push (fun _ -> None (* FIXME FIXME *)) in
        Lwt.async (fun () -> reader_loop bt.push sock p);
        Peer.start p;
        (* Hashtbl.add bt.peers addr !!p; FIXME XXX *)
        if Bits.is_set exts Wire.ltep_bit then Peer.send_extended_handshake p;
        if Bits.is_set exts Wire.dht_bit then Peer.send_port p 6881; (* FIXME fixed port *)
        loop (Peers.add id p peers) m

    | PeerDisconnected id ->
        bt.push (PeerMgr.peer_disconnected bt.peer_mgr id);
        loop (Peers.remove id peers) m

    | Choked _
    | Interested _
    | NotInterested _
    | Have _
    | HaveBitfield _ ->
        loop peers m

    | MetaRequested (id, _) ->
        (* Peer.send_reject_meta p i; *)
        (* FIXME *)
        loop peers m

    | GotMetaPiece (p, i, s) ->
        begin match m with
        | Some m' ->
            (* debug "got metadata piece %d/%d from %s" i *)
            (*   (IncompleteMetadata.piece_count m) (Peer.to_string p); *)
            if IncompleteMetadata.add_piece m' i s then begin
              match IncompleteMetadata.verify m' with
              | Some m' ->
                  debug "got full metadata";
                  let m' = Metadata.create (Bcode.decode m') in
                  Lwt.return m'
              | None ->
                  debug "metadata hash check failed; trying again";
                  loop peers None
            end else
              loop peers m
        | _ ->
            loop peers m
        end

    | RejectMetaPiece (p, i) ->
        (* debug "%s rejected request for metadata piece %d" (Peer.to_string p) i; *)
        (* FIXME *)
        loop peers m

    | BlockRequested _
    | BlockReceived _ ->
        loop peers m

    | GotPEX (p, added, dropped) ->
        (* debug "got pex from %s added %d dropped %d" (Peer.to_string p) *)
        (*   (List.length added) (List.length dropped); *)
        List.iter (fun (addr, _) -> bt.push (PeerMgr.add bt.peer_mgr addr)) added;
        loop peers m

    | DHTPort (p, i) ->
        (* debug "got dht port %d from %s" i (Peer.to_string p); *)
        (* let addr, _ = Peer.addr p in *)
        (* Lwt.async begin fun () -> *)
        (*   DHT.ping bt.dht (addr, i) >|= function *)
        (*   | Some (id, addr) -> *)
        (*       DHT.update bt.dht Kademlia.Good id addr *)
        (*   | None -> *)
        (*       debug "%s did not reply to dht ping on port %d" (Peer.to_string p) i *)
        (* end *)
        (* FIXME *)
        loop peers m
  in
  loop Peers.empty None

let start bt =
  List.iter (fun tier -> bt.push (Announce (tier, Some Tracker.STARTED))) bt.trackers;
  (* Listener.start bt.listener (); *)
  DHT.start bt.dht;
  Lwt.async begin fun () ->
    DHT.auto_bootstrap bt.dht DHT.bootstrap_nodes >>= fun () ->
    DHT.query_peers bt.dht bt.ih begin fun (id, addr) token peers ->
      bt.push (PeersReceived peers);
      Lwt.async begin fun () ->
        Lwt.catch
          (fun () -> DHT.announce bt.dht addr 6881 token bt.ih >>= fun _ -> Lwt.return ())
          (fun exn ->
             (* FIXME FIXME *)
             (* debug ~exn "dht announce to %s (%s) failed" (SHA1.to_hex_short id) (Addr.to_string addr); *)
             Lwt.return ())
      end
    end
  end;
  fetch_metadata bt >>= fun meta ->
  load_torrent bt meta >>= fun tor ->
  assert false

let listen_backlog = 5

let start_server ?(port = 0) push =
  let fd = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_any, 0));
  Lwt_unix.listen fd listen_backlog;
  debug "listening on port %u" port;
  let rec loop () =
    Lwt_unix.accept fd >>= fun (fd, sa) ->
    debug "accepted connection from %s" (Util.string_of_sockaddr sa);
    push (IncomingConnection (fd, sa));
    loop ()
  in
  loop ()

let create mg =
  let chan, push = Lwt_stream.create () in
  let push x = push (Some x) in
  let trackers = List.map (fun tr -> Tracker.Tier.create [tr]) mg.Magnet.tr in
  let id = SHA1.generate ~prefix:"OCAML" () in
  let ih = mg.Magnet.xt in
  let peer_mgr = PeerMgr.create () in
  (*       (fun sock id ext -> !!cl.push (PeerJoined (sock, id, ext))) *)
  (*       (\* (fun p e -> handle_peer_event !!cl p e) *\) *)
  (*       (fun p -> get_next_metadata_request !!cl p)) *)
  (* in *)
  Lwt.async (fun () -> start_server push);
  { id; ih; trackers; chan;
    push; peer_mgr;
    (* stage = NoMeta NoMetaLength; *)
    (* listener = Listener.create *)
        (* (fun fd _ -> assert false (\* FIXME FIXME PeerMgr.handle_incoming_peer !!peer_mgr (IO.of_file_descr fd)) *\)); *)
    dht = DHT.create 6881 }

(* let stats c = *)
(*   let downloaded = match c.stage with *)
(*     | HasMeta (_, Leeching (t, _, _)) *)
(*     | HasMeta (_, Seeding (t, _)) -> *)
(*         Torrent.have_size t *)
(*     | _ -> *)
(*         0L *)
(*   in *)
(*   let total_size = match c.stage with *)
(*     | HasMeta (m, _) -> Metadata.total_length m *)
(*     | NoMeta _ -> 0L *)
(*   in *)
(*   let have_pieces = match c.stage with *)
(*     | HasMeta (_, Leeching (t, _, _)) *)
(*     | HasMeta (_, Seeding (t, _)) -> Torrent.numgot t *)
(*     | _ -> 0 *)
(*   in *)
(*   let total_pieces = match c.stage with *)
(*     | HasMeta (m, _) -> Metadata.piece_count m *)
(*     | NoMeta _ -> 0 *)
(*   in *)
(*   let amount_left = match c.stage with *)
(*     | HasMeta (_, Leeching (t, _, _)) *)
(*     | HasMeta (_, Seeding (t, _)) -> Torrent.amount_left t *)
(*     | _ -> 0L *)
(*   in *)
(*   { Stats.upload_speed = PeerMgr.upload_speed c.peer_mgr; *)
(*     download_speed = PeerMgr.download_speed c.peer_mgr; *)
(*     num_connected_peers = PeerMgr.num_connected_peers c.peer_mgr; *)
(*     num_total_peers = PeerMgr.num_total_peers c.peer_mgr; *)
(*     downloaded; *)
(*     total_size; *)
(*     have_pieces; *)
(*     total_pieces; *)
(*     amount_left } *)
