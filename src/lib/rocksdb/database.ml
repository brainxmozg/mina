(* rocksdb.ml -- expose RocksDB operations for Mina *)

type t = { uuid : Uuid.Stable.V1.t; db : (Rocks.t[@sexp.opaque]) }
[@@deriving sexp]

let create directory =
  let opts = Rocks.Options.create () in
  Rocks.Options.set_create_if_missing opts true ;
  Rocks.Options.set_prefix_extractor opts
    (Rocks.Options.SliceTransform.Noop.create_no_gc ()) ;
  { uuid = Uuid_unix.create (); db = Rocks.open_db ~opts directory }

let create_checkpoint t dir =
  Rocks.checkpoint_create t.db ~dir ?log_size_for_flush:None () ;
  create dir

let make_checkpoint t dir =
  Rocks.checkpoint_create t.db ~dir ?log_size_for_flush:None ()

let get_uuid t = t.uuid

let close t = Rocks.close t.db

let get t ~(key : Bigstring.t) : Bigstring.t option =
  Rocks.get ?pos:None ?len:None ?opts:None t.db key

let get_batch t ~(keys : Bigstring.t list) : Bigstring.t option list =
  Rocks.multi_get t.db keys

let set t ~(key : Bigstring.t) ~(data : Bigstring.t) : unit =
  Rocks.put ?key_pos:None ?key_len:None ?value_pos:None ?value_len:None
    ?opts:None t.db key data

let[@warning "-16"] set_batch t ?(remove_keys : Bigstring.t list = [])
    ~(key_data_pairs : (Bigstring.t * Bigstring.t) list) : unit =
  let batch = Rocks.WriteBatch.create () in
  (* write to batch *)
  List.iter key_data_pairs ~f:(fun (key, data) ->
      Rocks.WriteBatch.put batch key data ) ;
  (* Delete any key pairs *)
  List.iter remove_keys ~f:(fun key -> Rocks.WriteBatch.delete batch key) ;
  (* commit batch *)
  Rocks.write t.db batch

module Batch = struct
  type t = Rocks.WriteBatch.t

  let remove t ~key = Rocks.WriteBatch.delete t key

  let set t ~key ~data = Rocks.WriteBatch.put t key data

  let with_batch t ~f =
    let batch = Rocks.WriteBatch.create () in
    let result = f batch in
    Rocks.write t.db batch ; result
end

let remove t ~(key : Bigstring.t) : unit =
  Rocks.delete ?pos:None ?len:None ?opts:None t.db key

let copy_bigstring t : Bigstring.t =
  let tlen = Bigstring.length t in
  let new_t = Bigstring.create tlen in
  Bigstring.blit ~src:t ~dst:new_t ~src_pos:0 ~dst_pos:0 ~len:tlen ;
  new_t

let to_alist t : (Bigstring.t * Bigstring.t) list =
  let iterator = Rocks.Iterator.create t.db in
  Rocks.Iterator.seek_to_last iterator ;
  (* iterate backwards and cons, to build list sorted by key *)
  let rec loop accum =
    if Rocks.Iterator.is_valid iterator then (
      let key = copy_bigstring (Rocks.Iterator.get_key iterator) in
      let value = copy_bigstring (Rocks.Iterator.get_value iterator) in
      Rocks.Iterator.prev iterator ;
      loop ((key, value) :: accum) )
    else accum
  in
  loop []

let foldi :
       t
    -> init:'a
    -> f:(int -> 'a -> key:Bigstring.t -> data:Bigstring.t -> 'a)
    -> 'a =
 fun t ~init ~f ->
  let iterator = Rocks.Iterator.create t.db in
  let rec loop i accum =
    if Rocks.Iterator.is_valid iterator then (
      let key = copy_bigstring (Rocks.Iterator.get_key iterator) in
      let data = copy_bigstring (Rocks.Iterator.get_value iterator) in
      Rocks.Iterator.next iterator ;
      loop (i + 1) (f i accum ~key ~data) )
    else accum
  in
  loop 0 init

let fold_until :
       t
    -> init:'a
    -> f:
         (   'a
          -> key:Bigstring.t
          -> data:Bigstring.t
          -> ('a, 'b) Continue_or_stop.t )
    -> finish:('a -> 'b)
    -> 'b =
 fun t ~init ~f ~finish ->
  let iterator = Rocks.Iterator.create t.db in
  let rec loop accum =
    if Rocks.Iterator.is_valid iterator then (
      let key = copy_bigstring (Rocks.Iterator.get_key iterator) in
      let data = copy_bigstring (Rocks.Iterator.get_value iterator) in
      Rocks.Iterator.next iterator ;
      match f accum ~key ~data with Stop _ -> accum | Continue v -> loop v )
    else accum
  in
  finish @@ loop init

let to_bigstring = Bigstring.of_string

let%test_unit "get_batch" =
  Async.Thread_safe.block_on_async_exn (fun () ->
      File_system.with_temp_dir "/tmp/mina-rocksdb-test" ~f:(fun db_dir ->
          let db = create db_dir in
          let[@warning "-8"] [ key1; key2; key3 ] =
            List.map ~f:(fun s -> Bigstring.of_string s) [ "a"; "b"; "c" ]
          in
          let data = Bigstring.of_string "test" in
          set db ~key:key1 ~data ;
          set db ~key:key3 ~data ;
          let[@warning "-8"] [ res1; res2; res3 ] =
            get_batch db ~keys:[ key1; key2; key3 ]
          in
          assert ([%equal: Bigstring.t option] res1 (Some data)) ;
          assert ([%equal: Bigstring.t option] res2 None) ;
          assert ([%equal: Bigstring.t option] res3 (Some data)) ;
          Async.Deferred.unit ) )

let%test_unit "to_alist (of_alist l) = l" =
  Async.Thread_safe.block_on_async_exn
  @@ fun () ->
  Async.Quickcheck.async_test ~trials:20
    Quickcheck.Generator.(
      tuple2 String.quickcheck_generator String.quickcheck_generator |> list)
    ~f:(fun kvs ->
      match Hashtbl.of_alist (module String) kvs with
      | `Duplicate_key _ ->
          Async.Deferred.unit
      | `Ok _ ->
          File_system.with_temp_dir "/tmp/mina-rocksdb-test" ~f:(fun db_dir ->
              let sorted =
                List.sort kvs ~compare:[%compare: string * string]
                |> List.map ~f:(fun (k, v) -> (to_bigstring k, to_bigstring v))
              in
              let db = create db_dir in
              List.iter sorted ~f:(fun (key, data) -> set db ~key ~data) ;
              let alist =
                List.sort (to_alist db)
                  ~compare:[%compare: Bigstring.t * Bigstring.t]
              in
              [%test_result: (Bigstring.t * Bigstring.t) list] ~expect:sorted
                alist ;
              close db ;
              Async.Deferred.unit ) )

let%test_unit "checkpoint read" =
  let open Async in
  Thread_safe.block_on_async_exn
  @@ fun () ->
  Quickcheck.async_test ~trials:20
    Quickcheck.Generator.(
      list @@ tuple2 String.quickcheck_generator String.quickcheck_generator)
    ~f:(fun kvs ->
      match Hashtbl.of_alist (module String) kvs with
      | `Duplicate_key _ ->
          Deferred.unit
      | `Ok db_hashtbl -> (
          let open Core in
          let cp_hashtbl = Hashtbl.copy db_hashtbl in
          let db_dir = Filename.temp_dir "test_db" "" in
          let cp_dir =
            Filename.temp_dir_name ^/ "test_cp"
            ^ String.init 16 ~f:(fun _ -> (Int.to_string (Random.int 10)).[0])
          in
          let db = create db_dir in
          Hashtbl.iteri db_hashtbl ~f:(fun ~key ~data ->
              set db ~key:(to_bigstring key) ~data:(to_bigstring data) ) ;
          let cp = create_checkpoint db cp_dir in
          match
            ( Hashtbl.add db_hashtbl ~key:"db_key" ~data:"db_data"
            , Hashtbl.add cp_hashtbl ~key:"cp_key" ~data:"cp_data" )
          with
          | `Ok, `Ok ->
              set db ~key:(to_bigstring "db_key") ~data:(to_bigstring "db_data") ;
              set cp ~key:(to_bigstring "cp_key") ~data:(to_bigstring "cp_data") ;
              let db_sorted =
                List.sort
                  (Hashtbl.to_alist db_hashtbl)
                  ~compare:[%compare: string * string]
                |> List.map ~f:(fun (k, v) -> (to_bigstring k, to_bigstring v))
              in
              let cp_sorted =
                List.sort
                  (Hashtbl.to_alist cp_hashtbl)
                  ~compare:[%compare: string * string]
                |> List.map ~f:(fun (k, v) -> (to_bigstring k, to_bigstring v))
              in
              let db_alist =
                List.sort (to_alist db)
                  ~compare:[%compare: Bigstring.t * Bigstring.t]
              in
              let cp_alist =
                List.sort (to_alist cp)
                  ~compare:[%compare: Bigstring.t * Bigstring.t]
              in
              [%test_result: (Bigstring.t * Bigstring.t) list] ~expect:db_sorted
                db_alist ;
              [%test_result: (Bigstring.t * Bigstring.t) list] ~expect:cp_sorted
                cp_alist ;
              close db ;
              close cp ;
              Deferred.unit
          | _ ->
              Deferred.unit ) )
