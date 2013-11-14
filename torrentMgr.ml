open Printf

let (>>=) = Lwt.(>>=)

let debug = Proc.debug

let string_of_msg = function
  | Msg.AddedTorrent path ->
    sprintf "AddedTorrent: %S" path

type t = {
  status_ch : Msg.status_msg Lwt_pipe.t;
  peer_mgr_ch : Msg.peer_mgr_msg Lwt_pipe.t;
  super_ch : Msg.super_msg Lwt_pipe.t;
  peer_id : Torrent.peer_id;
  id : Proc.Id.t
}

let add_torrent t path : unit Lwt.t =
  let torrent_info = Torrent.make (Bcode.from_file path) in
  Torrent.pp torrent_info;
  let ih = torrent_info.Torrent.info_hash in
  let piece_mgr_ch = Lwt_pipe.create () in
  let fs_ch = Lwt_pipe.create () in
  let sup_ch = Lwt_pipe.create () in
  let tracker_sup_ch = Lwt_pipe.create () in
  let start_trackers, tracker_chs = List.split (List.map (fun tier ->
    let ch = Lwt_pipe.create () in
    Msg.Worker (Tracker.start
      ~info_hash:ih
      ~tier
      ~peer_id:t.peer_id
      ~local_port:6881
      ~status_ch:t.status_ch
      ~peer_mgr_ch:t.peer_mgr_ch
      ~ch), ch) torrent_info.Torrent.announce_list)
  in
  let start_track_sup =
    Super.start Super.OneForOne "TrackerSup" ~children:start_trackers
      ~ch:tracker_sup_ch
  in
  lwt handles, have = Fs.open_and_check_file t.id torrent_info in
  let db = PieceMgr.create_piece_db have torrent_info.Torrent.pieces in
  let start_super = Super.start Super.AllForOne "TorrentSup"
    ~children:[
      Msg.Worker (Fs.start ~ch:fs_ch ~pieces:torrent_info.Torrent.pieces ~handles);
      Msg.Worker (PieceMgr.start ~ch:piece_mgr_ch ~status_ch:t.status_ch
        db ~info_hash:ih);
      Msg.Supervisor start_track_sup
    ]
    ~ch:sup_ch
  in
  Lwt_pipe.write t.super_ch (Msg.SpawnNew (Msg.Supervisor start_super));
  (* let _, send_fs = Fs.start ~send_super ~handles ~pieces in *)
  Lwt_pipe.write t.status_ch (Msg.InsertTorrent (ih,
    torrent_info.Torrent.total_length));
  let tl = { Msg.piece_mgr_ch; Msg.pieces = torrent_info.Torrent.pieces } in
  Lwt_pipe.write t.peer_mgr_ch (Msg.NewTorrent (ih, tl));
  List.iter (fun ch -> Lwt_pipe.write ch Msg.Start) tracker_chs;
  Lwt.return_unit

let handle_message t msg =
  debug t.id "%s" (string_of_msg msg) >>= fun () ->
  match msg with
  | Msg.AddedTorrent path ->
    add_torrent t path

let start ~super_ch ~status_ch ~peer_id ~peer_mgr_ch ~ch =
  let run id =
    let t = { super_ch; status_ch; peer_mgr_ch; peer_id; id } in
    Lwt_pipe.iter_s (handle_message t) ch
  in
  Proc.spawn ~name:"TorrentMgr" run (Super.default_stop super_ch)
    (fun _ -> Lwt.return_unit)
