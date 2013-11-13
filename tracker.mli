val start :
  super_ch:Msg.super_msg Lwt_pipe.t ->
  ch:Msg.tracker_msg Lwt_pipe.t ->
  info_hash:Torrent.Digest.t ->
  peer_id:Torrent.peer_id ->
  local_port:int ->
  tier:Uri.t list ->
  status_ch:Msg.status_msg Lwt_pipe.t ->
  peer_mgr_ch:Msg.peer_mgr_msg Lwt_pipe.t ->
  Proc.Id.t
