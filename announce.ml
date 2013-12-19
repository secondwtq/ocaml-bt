open Info
  
let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)
              
let failwith_lwt fmt =
  Printf.ksprintf (fun msg -> Lwt.fail (Failure msg)) fmt
                
type t = {
  tiers : Uri.t array array;
  info_hash : Word160.t;
  up : unit -> int64;
  down : unit -> int64;
  amount_left : unit -> int64;
  port : int;
  id : Word160.t;
  mutable running : bool;
  mutable force_stop : bool;
  mutable interval : float;
  mutable current_tier : int;
  mutable current_client : int;
  mutable thread : unit Lwt.t;
  handle_resp : Unix.sockaddr -> unit;
}

type event =
  | STARTED
  | STOPPED
  | NONE
  | COMPLETED

type success = {
  peers : Unix.sockaddr list;
  ival : int
}

type response =
  | Error of string
  | Warning of string
  | Success of success

let string_of_event = function
  | STARTED -> "STARTED"
  | STOPPED -> "STOPPED"
  | NONE -> "NONE"
  | COMPLETED -> "COMPLETED"

exception UnknownScheme of string option
exception HTTPError of string
exception AnnounceError of string

let shuffle_array a =
  for i = (Array.length a)-1 downto 1 do
    let j = Random.int (i+1) in
    let tmp = a.(i) in
    a.(i) <- a.(j);
    a.(j) <- tmp
  done

let create info up down amount_left port id handle_resp =
  let ann =
    { tiers = Array.of_list (List.map Array.of_list info.Info.announce_list);
      info_hash = info.Info.info_hash;
      up;
      down;
      amount_left;
      port;
      id;
      force_stop = false;
      interval = 5.;
      current_tier = 0;
      current_client = 0;
      handle_resp;
      running = false;
      thread = Lwt.return_unit }
  in
  let no_trackers =
    Array.fold_left (+) 0 (Array.map Array.length ann.tiers)
  in 
  Trace.infof "Announce initialised with %d trackers for %S" no_trackers info.Info.name;
  Array.iter shuffle_array ann.tiers;
  ann

let stop ann =
  Lwt.cancel ann.thread

let stop_hard ann =
  ann.force_stop <- true;
  stop ann
     
let udp_send fd buf =
  Lwt_unix.write fd buf 0 (String.length buf) >>= fun len ->
  if len <> String.length buf then
    failwith_lwt "udp_send: could not send entire packet"
  else
    Lwt.return_unit

let udp_packet_length = 512

let udp_recv fd =
  let buf = String.create udp_packet_length in
  Lwt_unix.read fd buf 0 udp_packet_length >>= fun len ->
  Lwt.return (String.sub buf 0 len)

let udp_fresh_transaction_id () =
  Random.int32 Int32.max_int

let rec udp_request_connect ann fd ev n =
  let trans_id = udp_fresh_transaction_id () in
  let put_packet =
    let open Put in
    let open Put.BE in
    int64 0x41727101980L >>
    int32 0l >>
    int32 trans_id
  in
  udp_send fd (Put.run put_packet) >>= fun () ->
  let handle_error = function
    | Unix.Unix_error (Unix.ETIMEDOUT, _, _) ->
      if n >= 8 then
        failwith_lwt "udp_request_connect: too many retries"
      else begin
        Trace.infof "UDP connect request timeout after %d s; retrying..."
          (truncate (15.0 *. 2.0 ** float n));
        udp_request_connect ann fd ev (n+1)
      end
    | exn -> Lwt.fail exn
  in
  Lwt_unix.setsockopt_float fd Lwt_unix.SO_RCVTIMEO (15.0 *. 2.0 ** float n);
  Lwt.catch (fun () -> udp_connect_response ann fd ev trans_id) handle_error

and udp_connect_response ann fd ev trans_id =
  udp_recv fd >>= fun buf ->
  let get_packet : response Lwt.t Get.t =
    let open Get in
    let open Get.BE in
    int32 >>= fun n ->
    if n = 3l then
      string >|= fun msg -> Lwt.return (Error msg)
    else begin
      int32 >>= fun trans_id' ->
      assert (Int32.compare trans_id trans_id' = 0);
      int64 >|= fun conn_id ->
      udp_request_announce ann fd ev conn_id 0
    end
  in
  Get.run get_packet buf

and udp_request_announce ann fd ev conn_id n =
  let trans_id = udp_fresh_transaction_id () in
  let create_packet =
    let open Put in
    let open Put.BE in
    int64 conn_id >>
    int32 1l >>
    int32 trans_id >>
    string (Word160.to_bin ann.info_hash) >>
    string (Word160.to_bin ann.id) >>
    int64 (ann.down ()) >>
    int64 (ann.amount_left ()) >>
    int64 (ann.up ()) >>
    int32
      begin match ev with
        | NONE -> 0l
        | COMPLETED -> 1l
        | STARTED -> 2l
        | STOPPED -> 3l
      end >>
    int32 0l >>
    int32 0l >>
    int32 (-1l) >>
    int16 ann.port
  in
  let handle_error = function
    | Unix.Unix_error (Unix.ETIMEDOUT, _, _) ->
      Trace.infof "ANNOUNCE UDP announce request timeout after %d s; retrying..."
        (truncate (15.0 *. 2.0 ** float n));
      if n >= 2 then udp_request_connect ann fd ev (n+1)
      else udp_request_announce ann fd ev conn_id (n+1)
    | exn ->
      Lwt.fail exn
  in
  udp_send fd (Put.run create_packet) >>= fun () ->
  Lwt_unix.setsockopt_float fd Lwt_unix.SO_RCVTIMEO (15.0 *. 2.0 ** float n);
  Lwt.catch (fun () -> udp_announce_response fd ev trans_id) handle_error

and udp_announce_response fd ev trans_id =
  let get_packet =
    let open Get in
    let open Get.BE in
    int32 >>= fun n ->
    assert (n = 1l || n = 3l);
    if n = 3l then (* error *)
      string >|= fun msg -> Error msg
    else begin
      int32 >>= fun trans_id' ->
      assert (Int32.compare trans_id trans_id' = 0);
      int32 >>= fun interval ->
      int32 >>= fun leechers ->
      int32 >>= fun seeders ->
      let rec loop () =
        let peer_info =
          uint8 >>= fun a ->
          uint8 >>= fun b ->
          uint8 >>= fun c ->
          uint8 >>= fun d ->
          uint16 >>= fun port ->
          let addr =
            Unix.inet_addr_of_string (Printf.sprintf "%03d.%03d.%03d.%03d" a b c d)
          in
          return (Unix.ADDR_INET (addr, port))
        in
        either (end_of_input >|= fun () -> [])
          (peer_info >>= fun pi -> loop () >>= fun rest -> return (pi :: rest))
      in
      loop () >|= fun new_peers ->
      Success
        { peers = new_peers;
          ival = Int32.to_int interval }
    end
  in
  try
    udp_recv fd >|= Get.run get_packet
  with
  | Get.Get_error -> failwith_lwt "udp_announce_response: packet too short"
  | exn -> Lwt.fail exn
             
let udp_announce ann url ev =
  let host = match Uri.host url with
    | None -> failwith "Empty Hostname"
    | Some host -> host
  in
  let port = match Uri.port url with
    | None -> failwith "Empty Port"
    | Some port -> port
  in
  Lwt_unix.gethostbyname host >>= fun he ->
  let addr = he.Lwt_unix.h_addr_list.(0) in
  let fd = Lwt_unix.socket Lwt_unix.PF_INET Lwt_unix.SOCK_DGRAM 0 in
  Lwt_unix.connect fd (Lwt_unix.ADDR_INET (addr, port)) >>= fun () ->
  udp_request_connect ann fd ev 0

let either f g x =
  try f x with _ -> g x

let http_decode_response (d : Bcode.t) =
  let success () =
    (* let seeders = *)
    (*   try Some (Bcode.find "complete" d |> Bcode.to_int) with Not_found -> None *)
    (* in *)
    (* let leechers = *)
    (*   try Some (Bcode.find "incomplete" d |> Bcode.to_int) with Not_found -> None *)
    (* in *)
    let interval = Bcode.find "interval" d |> Bcode.to_int in
    (* let min_interval = try Some (Bcode.find "min interval" d) with _ -> None in *)
    let compact_peers peers =
      let pr = Bcode.to_string peers in
      let rec loop i =
        if i >= String.length pr then []
        else
          let addr =
            Unix.inet_addr_of_string
              (Printf.sprintf "%03d.%03d.%03d.%03d"
                 (int_of_char pr.[i+0]) (int_of_char pr.[i+1])
                 (int_of_char pr.[i+2]) (int_of_char pr.[i+3]))
          in
          let port = int_of_char pr.[i+4] lsl 8 + int_of_char pr.[i+5] in
          Unix.ADDR_INET (addr, port) :: loop (i+6)
      in
      loop 0
    in
    let usual_peers peers =
      Bcode.to_list peers |>
      List.map (fun d ->
          let ip = Bcode.find "ip" d |> Bcode.to_string in
          let port = Bcode.find "port" d |> Bcode.to_int in
          let addr = Unix.inet_addr_of_string ip in
          Unix.ADDR_INET (addr, port))
    in
    let peers = Bcode.find "peers" d in
    let peers = either compact_peers usual_peers peers in
    Success {peers; ival = interval}
  in
  let error () =
    let s = Bcode.find "failure reason" d |> Bcode.to_string in
    Error s
  in
  let warning () =
    let s = Bcode.find "warning message" d |> Bcode.to_string in
    Warning s
  in
  either warning (either error success) ()

let http_announce ann url event =
  let uri =
    let params =
      ("info_hash",   Word160.to_bin ann.info_hash) ::
      ("peer_id",     Word160.to_bin ann.id) ::
      ("uploaded",    Int64.to_string (ann.up ())) ::
      ("downloaded",  Int64.to_string (ann.down ())) ::
      ("left",        Int64.to_string (ann.amount_left ())) ::
      ("port",        string_of_int ann.port) ::
      ("compact",     "1") ::
      match event with
      | NONE -> []
      | _ -> ("event", String.lowercase (string_of_event event)) :: []
    in
    Uri.add_query_params' url params
  in
  Cohttp_lwt_unix.Client.get uri >>= function
  | None -> Lwt.fail (HTTPError "no response")
  | Some (resp, body) ->
    Cohttp_lwt_body.string_of_body body >>= fun body ->
    Trace.infof "Received response from HTTP tracker body: %S" body;
    try
      Get.run Bcode.bdecode body |> http_decode_response |> Lwt.return
    with exn ->
      Lwt.fail (HTTPError ("decode error: " ^ Printexc.to_string exn))

let announce ann event =
  let url = ann.tiers.(ann.current_tier).(ann.current_client) in
  Trace.infof "ANNOUNCE QUERY event:%s tracker:%s ul:%Ld dl:%Ld left:%Ld"
    (string_of_event event) (Uri.to_string url) (ann.up ())
    (ann.down ()) (ann.amount_left ());
  match Uri.scheme url with
  | Some "http" | Some "https" ->
    (* failwith_lwt "skipping over http trackers for now..." *)
    http_announce ann url event
  | Some "udp" ->
    udp_announce ann url event
  | other ->
    Lwt.fail (UnknownScheme other)

(* let silent ann f = *)
(*   let old_hdl = ann.handlers in *)
(*   ann.handlers <- []; *)
(*   f () >>= fun res -> *)
(*   ann.handlers <- old_hdl; *)
(*   Lwt.return res *)

let promote_tracker ann =
  Trace.infof "Promoting tracker %s (tier %d, pos %d)"
    (Uri.to_string ann.tiers.(ann.current_tier).(ann.current_client))
    ann.current_tier ann.current_client;
  let tier = ann.tiers.(ann.current_tier) in
  let tmp = tier.(0) in
  tier.(0) <- tier.(ann.current_client);
  tier.(ann.current_client) <- tmp;
  ann.current_client <- 0

let try_trackers f ann =
  let rec loop tier client =
    if tier >= Array.length ann.tiers then
      loop 0 0
    else if client >= Array.length ann.tiers.(tier) then
      loop (tier+1) 0
    else begin
      ann.current_tier <- tier;
      ann.current_client <- client;
      Trace.infof "Switching trackers to %s (tier %d, pos %d)"
        (Uri.to_string ann.tiers.(tier).(client)) tier client;
      Lwt.catch f
        (fun exn ->
           Trace.infof ~exn "Announce error";
           loop tier (client+1))
    end
  in
  loop 0 0

let set_interval ann iv =
  if iv <= 0 then stop ann
  else
    if float iv <> ann.interval then begin
      Trace.infof "Announce interval set to %ds." iv;
      ann.interval <- float iv
    end

let run ann =
  Trace.infof "Starting announce.";
  ann.interval <- 5.;
  let rec loop ev =
    try_trackers (fun () ->
        announce ann ev >>= function
        | Warning err | Error err ->
          Lwt.fail (AnnounceError err)
        | Success success ->
          promote_tracker ann;
          set_interval ann success.ival;
          List.iter ann.handle_resp success.peers;
          Lwt.return_unit) ann >>= fun () ->
    Lwt_unix.sleep ann.interval >>= fun () ->
    loop NONE
  in
  loop STARTED >>= fun () ->
  Trace.infof "Stopping announce.";
  if not ann.force_stop then
    (* silent ann (fun () -> *)
    Lwt.catch (fun () -> announce ann STOPPED >>= fun _ -> Lwt.return_unit)
      (fun exn -> Trace.infof ~exn "ignoring (shutting down)"; Lwt.return_unit)
  else
    Lwt.return_unit

let start ann =
  ann.force_stop <- false;
  if ann.running then
    Trace.infof "already running; what is going on?"
  else begin
    ann.thread <-
      Lwt.catch (fun () -> run ann) (fun exn ->
          Trace.infof ~exn "Unexpected error while announcing";
          Lwt.return_unit);
    Lwt.on_termination ann.thread (fun () -> ann.running <- false)
  end
