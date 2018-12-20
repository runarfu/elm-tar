module Tar exposing (..)

{-| Use

       encodeFiles : List ( FileRecord, Data ) -> Encode.Encoder

to tar an arbitrary set of files which may contain either text or binary
data. To tar a set of text files, you can use

       encodeTextFiles : List (FileRecord, String) -> Encode.Encoder

For more details, see the README. See also the demo app `./examples/Main.elm`

@docs Data, FileRecord, encodeFiles, encodeTextFiles, defaultFileRecord

-}

{- (Data(..), FileRecord, encodeFiles, encodeTextFiles, defaultFileRecord) -}

import Bytes exposing (..)
import Bytes.Decode as Decode exposing (Decoder, decode)
import Bytes.Encode as Encode exposing (encode)
import Time exposing (Posix)
import Char
import CheckSum
import Octal exposing (octalEncoder)


{-| Use `StringData String` for text data,
`BinaryData Bytes` for binary data, e.g.,
`StringData "This is a test"` or
`BinaryData someBytes`
-}
type Data
    = StringData String
    | BinaryData Bytes


{-| A FileRecord contains the information needed for
tar to construct the header for the assoicated file
in the tar archive. You may use `defaultFileRecord` as
a starting point, modifying only what is needed.
-}
type alias FileRecord =
    { filename : String
    , mode : Mode
    , ownerID : Int
    , groupID : Int
    , fileSize : Int
    , lastModificationTime : Int
    , linkIndicator : Link
    , linkedFileName : String
    , userName : String
    , groupName : String
    , fileNamePrefix : String
    }


type alias Mode =
    { user : List FilePermission
    , group : List FilePermission
    , other : List FilePermission
    , system : List SystemInfo
    }


type SystemInfo
    = SUID
    | SGID
    | SVTX


type FilePermission
    = Read
    | Write
    | Execute


type Link
    = NormalFile
    | HardLink
    | SymbolicLink



--
-- DECODE FILES
--


{-| (2)
-}
type alias FileData =
    { fileName : String
    , length : Int
    }


type HeaderInfo
    = FileHeader FileData
    | NullBlock
    | Error


decodeFile : Decoder ( FileData, Data )
decodeFile =
    decodeFileHeader
        |> Decode.andThen (\fileData -> decodeStringBody fileData)


{-| (6)
-}
decodeTextFile : Decoder ( FileData, Data )
decodeTextFile =
    decodeFileHeader
        |> Decode.andThen (\fileData -> decodeStringBody fileData)


{-| (3)
-}
decodeFileHeader : Decoder FileData
decodeFileHeader =
    Decode.bytes 512
        |> Decode.map (\bytes -> getFileData bytes)


{-| (4)

> tf |> getFileData
> { fileName = "test.txt", length = 512 }

-}
getHeaderInfo : Bytes -> HeaderInfo
getHeaderInfo bytes =
    case isHeader_ bytes of
        True ->
            FileHeader (getFileData bytes)

        False ->
            NullBlock


getFileData : Bytes -> FileData
getFileData bytes =
    let
        blockIsHeader =
            isHeader_ bytes

        fileName =
            getFileName bytes
                |> Maybe.withDefault "unknownFileName"

        length =
            getFileLength bytes
    in
        { fileName = fileName, length = length }


{-| (5)
Round integer up to nearest multiple of 512.
-}
round512 : Int -> Int
round512 n =
    let
        residue =
            modBy 512 n
    in
        if residue == 0 then
            n
        else
            n + (512 - residue)


{-| (1*)
-}
decodeStringBody : FileData -> Decoder ( FileData, Data )
decodeStringBody fileData =
    Decode.string (round512 fileData.length)
        |> Decode.map (\str -> ( fileData, StringData (String.left fileData.length str) ))


{-| isHeader bytes == True if and only if
bytes has width 512 and contains the
string "ustar"
-}
isHeader : Bytes -> Bool
isHeader bytes =
    if Bytes.width bytes == 512 then
        isHeader_ bytes
    else
        False


isHeader_ : Bytes -> Bool
isHeader_ bytes =
    bytes
        |> decode (Decode.string 512)
        |> Maybe.map (\str -> String.slice 257 262 str == "ustar")
        |> Maybe.withDefault False


getFileName : Bytes -> Maybe String
getFileName bytes =
    bytes
        |> decode (Decode.string 100)
        |> Maybe.map (String.replace (String.fromChar (Char.fromCode 0)) "")


getFileLength : Bytes -> Int
getFileLength bytes =
    bytes
        |> decode (Decode.string 256)
        |> Maybe.map (String.slice 124 136)
        |> Maybe.map (stripLeadingString "0")
        |> Maybe.map String.trim
        |> Maybe.andThen String.toInt
        |> Maybe.withDefault 0


stripLeadingString : String -> String -> String
stripLeadingString lead str =
    str
        |> String.split ""
        |> stripLeadingElement lead
        |> String.join ""


stripLeadingElement : a -> List a -> List a
stripLeadingElement lead list =
    case list of
        [] ->
            []

        [ x ] ->
            if lead == x then
                []
            else
                [ x ]

        x :: xs ->
            if lead == x then
                stripLeadingElement lead xs
            else
                x :: xs



--
-- ENCODE FILES
--


{-| Example

encodeFiles [(defaultFileRecord, "This is a test"), (defaultFileRecord, "Lah di dah do day!")] |> Bytes.Encode.encode == <2594 bytes> : Bytes

-}
encodeTextFiles : List ( FileRecord, String ) -> Encode.Encoder
encodeTextFiles fileList =
    Encode.sequence
        ((List.map (\item -> encodeTextFile (Tuple.first item) (Tuple.second item)) fileList)
            ++ [ Encode.string (normalizeString 1024 "") ]
        )


{-|

      Example

      import Tar exposing(defaultFileRecord)

      fileRecord_ =
          defaultFileRecord

      fileRecord1 =
          { fileRecord_ | filename = "a.txt" }

      content1 =
          "One two three\n"

      fileRecord2 =
          { fileRecord_ | filename = "c.binary" }

      content2 =
          Hex.toBytes "616263646566" |> Maybe.withDefault (encode (Bytes.Encode.unsignedInt8 0))

      Tar.encodeFiles
          [ ( fileRecord1, StringData content1 )
          , ( fileRecord2, BinaryData content2 )
          ]
          |> Bytes.Encode.encode

      Note: `Hex` is found in `jxxcarlson/hex`
-}
encodeFiles : List ( FileRecord, Data ) -> Encode.Encoder
encodeFiles fileList =
    Encode.sequence
        ((List.map (\item -> encodeFile (Tuple.first item) (Tuple.second item)) fileList)
            ++ [ Encode.string (normalizeString 1024 "") ]
        )


encodeTextFile : FileRecord -> String -> Encode.Encoder
encodeTextFile fileRecord_ contents =
    let
        fileRecord =
            { fileRecord_ | fileSize = String.length contents }
    in
        Encode.sequence
            [ encodeFileRecord fileRecord
            , Encode.string (padContents contents)
            ]


encodeFile : FileRecord -> Data -> Encode.Encoder
encodeFile fileRecord_ data =
    case data of
        StringData contents ->
            encodeTextFile fileRecord_ contents

        BinaryData bytes ->
            encodeBinaryFile fileRecord_ bytes


encodeBinaryFile : FileRecord -> Bytes -> Encode.Encoder
encodeBinaryFile fileRecord_ bytes =
    let
        fileRecord =
            { fileRecord_ | fileSize = Bytes.width bytes }
    in
        Encode.sequence
            [ encodeFileRecord fileRecord
            , encodePaddedBytes bytes
            ]


encodePaddedBytes : Bytes -> Encode.Encoder
encodePaddedBytes bytes =
    let
        paddingWidth =
            modBy 512 (Bytes.width bytes) |> (\x -> 512 - x)
    in
        Encode.sequence
            [ Encode.bytes bytes
            , Encode.sequence <| List.repeat paddingWidth (Encode.unsignedInt8 0)
            ]


{-| defaultFileRecord is a dummy FileRecord that you modify
to suit your needs. It contains a lot of boilerplates

Example

fileRecord = { defaultFileRecord | filename = "Test.txt" }

See the definition of FileRecord to see what other fields you
may want to modify, or see `/examples/Main.elm`.

-}
defaultFileRecord : FileRecord
defaultFileRecord =
    FileRecord
        "test.txt"
        blankMode
        501
        20
        123
        1542665285
        NormalFile
        ""
        "anonymous"
        "staff"
        ""


{-| Add zeros at end of file to make its length a multiple of 512.
-}
padContents : String -> String
padContents str =
    let
        paddingLength =
            modBy 512 (String.length str) |> (\x -> 512 - x)

        nullString =
            String.fromChar (Char.fromCode 0)

        padding =
            String.repeat paddingLength nullString
    in
        str ++ padding



--
-- ENCODE FILE RECORD
--


encodedSpace =
    Encode.string " "


encodedZero =
    Encode.string "0"


encodedNull =
    Encode.string (String.fromChar (Char.fromCode 0))


encodeFileRecord : FileRecord -> Encode.Encoder
encodeFileRecord fileRecord =
    let
        fr =
            preliminaryEncodeFileRecord fileRecord |> encode
    in
        Encode.sequence
            [ Encode.string (normalizeString 100 fileRecord.filename)
            , encodeMode fileRecord.mode
            , Encode.sequence [ octalEncoder 6 fileRecord.ownerID, encodedSpace, encodedNull ]
            , Encode.sequence [ octalEncoder 6 fileRecord.groupID, encodedSpace, encodedNull ]
            , Encode.sequence [ octalEncoder 11 fileRecord.fileSize, encodedSpace ]
            , Encode.sequence [ octalEncoder 11 fileRecord.lastModificationTime, encodedSpace ]
            , Encode.sequence [ CheckSum.sumEncoder fr, encodedNull, encodedSpace ]
            , linkEncoder fileRecord.linkIndicator
            , Encode.string (normalizeString 100 fileRecord.linkedFileName)
            , Encode.sequence [ Encode.string "ustar", encodedNull ]
            , Encode.string "00"
            , Encode.string (normalizeString 32 fileRecord.userName)
            , Encode.string (normalizeString 32 fileRecord.groupName)
            , Encode.sequence [ octalEncoder 6 0, encodedSpace ]
            , Encode.sequence [ encodedNull, octalEncoder 6 0, encodedSpace ]
            , Encode.string (normalizeString 168 fileRecord.fileNamePrefix)
            ]


preliminaryEncodeFileRecord : FileRecord -> Encode.Encoder
preliminaryEncodeFileRecord fileRecord =
    Encode.sequence
        [ Encode.string (normalizeString 100 fileRecord.filename)
        , encodeMode fileRecord.mode
        , Encode.sequence [ octalEncoder 6 fileRecord.ownerID, encodedSpace, encodedNull ]
        , Encode.sequence [ octalEncoder 6 fileRecord.groupID, encodedSpace, encodedNull ]
        , Encode.sequence [ octalEncoder 11 fileRecord.fileSize, encodedSpace ]
        , Encode.sequence [ octalEncoder 11 fileRecord.lastModificationTime, encodedSpace ]
        , Encode.string "        "
        , encodedSpace -- slinkEncoder fileRecord.linkIndicator
        , Encode.string (normalizeString 100 fileRecord.linkedFileName)
        , Encode.sequence [ Encode.string "ustar", encodedNull ]
        , Encode.string "00"
        , Encode.string (normalizeString 32 fileRecord.userName)
        , Encode.string (normalizeString 32 fileRecord.groupName)
        , Encode.sequence [ octalEncoder 6 0, encodedSpace ]
        , Encode.sequence [ encodedNull, octalEncoder 6 0, encodedSpace ]
        , Encode.string (normalizeString 168 fileRecord.fileNamePrefix)
        ]



--
-- ENCODERS
--


linkEncoder : Link -> Encode.Encoder
linkEncoder link =
    case link of
        NormalFile ->
            Encode.string "0"

        HardLink ->
            Encode.string "1"

        SymbolicLink ->
            Encode.string "2"


blankMode =
    Mode [ Read, Write ] [ Read ] [ Read ] [ SGID ]


encodeFilePermission : FilePermission -> Int
encodeFilePermission fp =
    case fp of
        Read ->
            4

        Write ->
            2

        Execute ->
            1


encodeFilePermissions : List FilePermission -> Encode.Encoder
encodeFilePermissions fps =
    fps
        |> List.map encodeFilePermission
        |> List.sum
        |> (\x -> x + 48)
        |> Encode.unsignedInt8


encodeSystemInfo : SystemInfo -> Int
encodeSystemInfo si =
    case si of
        SVTX ->
            1

        SGID ->
            2

        SUID ->
            4


encodeSystemInfos : List SystemInfo -> Encode.Encoder
encodeSystemInfos sis =
    sis
        |> List.map encodeSystemInfo
        |> List.sum
        |> (\x -> x + 48)
        |> Encode.unsignedInt8


encodeMode : Mode -> Encode.Encoder
encodeMode mode =
    Encode.sequence
        [ Encode.unsignedInt8 48
        , Encode.unsignedInt8 48
        , Encode.unsignedInt8 48
        , encodeFilePermissions mode.user
        , encodeFilePermissions mode.group
        , encodeFilePermissions mode.other
        , Encode.unsignedInt8 32 -- encodeSystemInfos mode.system
        , Encode.unsignedInt8 0
        ]


encodeInt8 : Int -> Encode.Encoder
encodeInt8 n =
    Encode.sequence
        [ Encode.unsignedInt32 BE 0
        , Encode.unsignedInt32 BE n
        ]


encodeInt12 : Int -> Encode.Encoder
encodeInt12 n =
    Encode.sequence
        [ Encode.unsignedInt32 BE 0
        , Encode.unsignedInt32 BE 0
        , Encode.unsignedInt32 BE n
        ]


{-| return string of length n, truncated
if necessary, and then padded, if neccessary,
with 0's on the right.
-}
normalizeString : Int -> String -> String
normalizeString n str =
    str |> String.left n |> String.padRight n (Char.fromCode 0)



{- NOTES -}
{- @gabber

   / untested
   myzip : List Bytes -> Bytes.Encode.Encoder
   myzip files =
       let
           file_encoder : Bytes-> Bytes.Encode.Encoder
           file_encoder file =
               Bytes.Encode.sequence
                   [ Bytes.Encode.unsignedInt32 Bytes.Encode.BE <| Bytes.width file
                   , Bytes.Encode.bytes file
                   ]
       in
       Encode.sequence <|
           [ Bytes.Encode.unsignedInt8 <| List.length files ]
           ++ List.map file_encoder files

-}
