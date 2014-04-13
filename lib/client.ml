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
let (>|=) = Lwt.(>|=)

module H = Word160

let max_num_peers = 30
let max_connections = 5
let listen_ports = [50000]
let max_requests = 5

type event =
  | IncomingPeer of Tcp.socket * Addr.t
  | PeersReceived of Addr.t list
  | PeerEvent of Peer.t * Peer.event
  | GotMetadata of Meta.t
  | TorrentLoaded of int * int * Bits.t
  | PieceVerified of int
  | TorrentCompleted

type metadata_state =
  | Nothing
  | Partial of string * bool array * int ref
  | Complete of Meta.t

type stage =
  | NoMeta
  | PartialMeta of Meta.partial
  | Loading of Meta.t * Torrent.t
  | Leeching of Meta.t * Torrent.t
  | Seeding of Meta.t * Torrent.t

type t = {
  id : H.t;
  ih : H.t;
  trackers : Tracker.t list list;
  peers : (Addr.t, Peer.t) Hashtbl.t;
  connecting : (Addr.t, unit) Hashtbl.t;
  chan : event Lwt_stream.t;
  push : event -> unit;
  mutable stage : stage;
}

let create mg =
  (* let mg = Magnet.of_string s in *)
  let chan, push = Lwt_stream.create () in
  let push x = push (Some x) in
  { id = H.peer_id "OCTO";
    ih = mg.Magnet.xt;
    trackers = List.map (fun tr -> [Tracker.create tr]) mg.Magnet.tr;
    peers = Hashtbl.create 17;
    connecting = Hashtbl.create 17;
    chan;
    push;
    stage = NoMeta }

exception Cant_listen

let create_server handle =
  let sock = Tcp.create_socket () in
  let rec loop = function
    | [] ->
      raise Cant_listen
    | p :: ports ->
      try
        let stop = Tcp.listen sock p handle in
        Log.info "listening on port %d" p;
        p, stop
      with _ -> loop ports
  in
  loop listen_ports

let push_incoming_peer bt sock addr =
  bt.push (IncomingPeer (sock, addr))

let push_peers_received bt xs =
  bt.push (PeersReceived xs)

let push_peer_event bt p ev =
  bt.push (PeerEvent (p, ev))

let push_metadata bt info =
  bt.push (GotMetadata info)

let proto = "BitTorrent protocol"

let read_handshake sock =
  let get_handshake =
    let open Get in
    char (String.length proto |> Char.chr) >>
    string proto >>
    string_of_length 8 >|= Bits.of_bin >>= fun extbits ->
    string_of_length 20 >|= Word160.from_bin >>= fun ih ->
    string_of_length 20 >|= Word160.from_bin >>= fun id ->
    return (ih, id, extbits)
  in
  Tcp.read sock (49 + String.length proto) >|= Get.run get_handshake

let extended_bits =
  let bits = Bits.create (8 * 8) in
  Bits.set bits Wire.lt_extension_bit;
  bits

let handshake_message id ih =
  Printf.sprintf "%c%s%s%s%s"
    (String.length proto |> Char.chr) proto
    (Bits.to_bin extended_bits)
    (Word160.to_bin ih)
    (Word160.to_bin id)

let add_peer bt sock addr ih id exts =
  if Hashtbl.length bt.peers < max_num_peers then begin
    let p = Peer.create sock id in
    Peer.start p (push_peer_event bt p);
    if Bits.is_set exts Wire.lt_extension_bit then Peer.send_extended_handshake p;
    Hashtbl.add bt.peers addr p
  end else begin
    Log.warning "too many peers; rejecting new peer (addr=%s)" (Addr.to_string addr);
    Tcp.close sock |> ignore
  end

let handle_incoming_peer bt sock addr =
  Log.info "incoming peer (addr=%s,present=%b)" (Addr.to_string addr) (Hashtbl.mem bt.peers addr);
  if not (Hashtbl.mem bt.peers addr) then begin
    Lwt.catch
      (fun () ->
         read_handshake sock >>= fun (ih, id, exts) ->
         Tcp.write sock (handshake_message bt.id ih) >|= fun () ->
         add_peer bt sock addr ih id exts)
      (fun e ->
         Log.error ~exn:e "peer handshake failed"; Lwt.return ()) |> ignore
  end else
    Tcp.close sock |> ignore

let handle_received_peer bt addr =
  Log.info "received peer (addr=%s,present=%b,connecting=%b)"
    (Addr.to_string addr) (Hashtbl.mem bt.peers addr) (Hashtbl.mem bt.connecting addr);
  if not (Hashtbl.mem bt.peers addr || Hashtbl.mem bt.connecting addr) then begin
    Hashtbl.add bt.connecting addr ();
    Lwt.finalize
      (fun () ->
         let sock = Tcp.create_socket () in
         Tcp.connect sock addr >>= fun () ->
         Tcp.write sock (handshake_message bt.id bt.ih) >>= fun () ->
         read_handshake sock >>= fun (ih, id, exts) ->
         Log.success "handshake successful (addr=%s,ih=%s,id=%s)"
           (Addr.to_string addr) (Word160.to_hex_short ih) (Word160.to_hex_short id);
         add_peer bt sock addr ih id exts;
         Lwt.return ())
      (fun () ->
         Hashtbl.remove bt.connecting addr; Lwt.return ())
  end else begin
    Lwt.return ()
  end

let info_piece_size = 16 * 1024

let roundup n r =
  (n + r - 1) / r * r

let has_metadata bt =
  match bt.stage with
  | Loading _
  | Leeching _
  | Seeding _ -> true
  | _ -> false

let has_partial_metadata bt =
  match bt.stage with
  | NoMeta -> false
  | PartialMeta _
  | Loading _
  | Leeching _
  | Seeding _ -> true

let request_meta_piece bt (p : Peer.t) =
  match bt.stage with
  | PartialMeta meta ->
    begin match Meta.pick_missing meta with
    | None -> ()
    | Some i -> Peer.request_meta_piece p i
    end
  | _ ->
    ()

let handle_available_metadata bt p len =
  match bt.stage with
  | NoMeta ->
    bt.stage <- PartialMeta (Meta.create_partial bt.ih len);
    let npieces = roundup len info_piece_size / info_piece_size in
    Log.success "metadata available (len=%d,npieces=%d)" len npieces;
    request_meta_piece bt p
  | _ ->
    ()

let request_block bt p =
  match bt.stage with
  | Leeching (_, t) ->
    begin match Torrent.request_block t (Peer.has_piece p) with
    | None ->
      Peer.send_not_interested p
    | Some pc ->
      Peer.send_request p pc
    end
  | _ -> ()
  
let handle_peer_event bt p = function
  | Peer.Finished reqs ->
    Hashtbl.remove bt.peers (Peer.addr p);
    begin match bt.stage with
    | Leeching (_, dl) ->
      Torrent.lost_bitfield dl (Peer.have p)
    | _ -> ()
    end
  | Peer.AvailableMetadata len ->
    handle_available_metadata bt p len
  | Peer.Choked reqs ->
    begin match bt.stage with
    | Leeching (_, t) -> List.iter (Torrent.lost_request t) reqs
    | _ -> ()
    end
  | Peer.Unchoked ->
    Log.info "peer just unchoked us (addr=%s)" (Addr.to_string (Peer.addr p));
    for i = 1 to max_requests do
      request_block bt p
    done
  | Peer.Have i ->
    begin match bt.stage with
    | Leeching (_, dl) ->
      if Torrent.got_have dl i then Peer.send_interested p
    | _ -> ()
    end
  | Peer.HaveBitfield b ->
    begin match bt.stage with
    | Leeching (_, dl) ->
      if Torrent.got_bitfield dl b then Peer.send_interested p
    | _ -> ()
    end
  | Peer.MetaRequested i ->
    begin match bt.stage with
    | NoMeta
    | PartialMeta _ ->
      Peer.send_reject_meta p i
    | Loading (meta, _)
    | Leeching (meta, _)
    | Seeding (meta, _) ->
      Peer.send_meta_piece p i (Meta.length meta, Meta.get_piece meta i)
    end
  | Peer.GotMetaPiece (i, s) ->
    begin match bt.stage with
    | PartialMeta meta ->
      if Meta.add_piece meta i s then
        match Meta.verify meta with
        | Some meta ->
          Log.success "got complete metadata";
          push_metadata bt meta
        | None ->
          Log.error "metadata hash check failed";
          bt.stage <- NoMeta
      else
        request_meta_piece bt p
    | _ ->
      ()
    end
  | Peer.RejectMetaPiece i ->
    request_meta_piece bt p
  | Peer.BlockRequested (idx, off, len) ->
    begin match bt.stage with
    | Leeching (_, dl)
    | Seeding (_, dl) ->
      if Torrent.has_piece dl idx then begin
        let aux _ =
          Torrent.get_block dl idx off len >|= Peer.send_block p idx off
        in
        Lwt.async aux
      end
    | _ ->
      ()
    end
  | Peer.BlockReceived (idx, off, s) ->
    begin match bt.stage with
    | Leeching (meta, t) ->
      Log.success "received block (idx=%d,off=%d,len=%d)" idx off (String.length s);
      let aux () =
        Torrent.got_block t idx off s >|= function
        | `Verified ->
          bt.push (PieceVerified idx);
          if Torrent.is_complete t then bt.push TorrentCompleted
        | `Failed
        | `Continue -> ()
      in
      Lwt.async aux;
      request_block bt p
    | _ ->
      ()
    end
  | Peer.Interested ->
    ()
  | Peer.NotInterested ->
    ()
  | Peer.Port _ ->
    ()

let handle_event bt = function
  | IncomingPeer (sock, addr) ->
    handle_incoming_peer bt sock addr
  | PeersReceived addrs ->
    Log.success "received %d peers" (List.length addrs);
    let aux () = Lwt_list.iter_p (fun addr ->
        Lwt.catch
          (fun () -> handle_received_peer bt addr)
          (fun e ->
             Log.error ~exn:e "connection failed (addr=%s)" (Addr.to_string addr);
             Lwt.return ())) addrs in
    Lwt.async aux
  | PeerEvent (p, e) ->
    handle_peer_event bt p e
  | GotMetadata meta ->
    let t = Torrent.create meta in
    bt.stage <- Loading (meta, t);
    let aux () =
      Torrent.update t >|= fun (good, tot, bits) -> bt.push (TorrentLoaded (good, tot, bits))
    in
    Lwt.async aux
  | TorrentLoaded (good, total, bits) ->
    begin match bt.stage with
    | Loading (meta, t) ->
      Log.success "torrent loaded (good=%d,total=%d)" good total;
      bt.stage <- if Torrent.is_complete t then Seeding (meta, t) else Leeching (meta, t);
      let wakeup_peer _ p =
        Peer.send_have_bitfield p bits;
        if Torrent.got_bitfield t (Peer.have p) then begin
          Log.success "we should be interested in %s" (Addr.to_string (Peer.addr p));
          Peer.send_interested p;
          if not (Peer.peer_choking p) then
            for i = 1 to max_requests do request_block bt p done
        end else
          Peer.send_not_interested p
      in
      Hashtbl.iter wakeup_peer bt.peers
    | _ ->
      ()
    end
  | PieceVerified i ->
    Log.success "piece verified and written to disk (idx=%d)" i
  | TorrentCompleted ->
    Log.success "torrent completed!";
    begin match bt.stage with
    | Leeching (meta, t) -> bt.stage <- Seeding (meta, t)
    | _ -> ()
    end

let event_loop bt =
  let rec loop () =
    Lwt_stream.next bt.chan >|= handle_event bt >>= loop
  in
  loop ()

let start bt =
  let port, _ = create_server (push_incoming_peer bt) in
  Log.info "starting";
  Lwt_list.iter_p (fun tr ->
      Tracker.query tr bt.ih port bt.id >|= fun resp ->
      push_peers_received bt resp.Tracker.peers) (List.flatten bt.trackers) |> ignore;
  event_loop bt