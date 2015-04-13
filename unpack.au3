#NoTrayIcon
#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_UseX64=y
#AutoIt3Wrapper_Change2CUI=y
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****

#include <FileConstants.au3>
#include <String.au3>
#include <Array.au3>
#include <File.au3>
#include "inc\Binary.au3"
#include "inc\Common.au3"

Global Const $MEM_ADDR = "20200000"
Global Const $FILE_PART_CMD = "filepartload " & $MEM_ADDR & " MstarUpgrade.bin"

Global $aPartOffset[0]
Global $aPartLength[0]
Global $aPartLabel[0]
Global $aPartType[0]

Global $iPostHeaderPadding = 0
Global $aPostChunkPadding[0]

Global $iCRC32_script
Global $iCRC32_unknown
Global $sFooterCmd

Global $iLastPos ; temp val for storing current operating position in binary file
Global $iChunkPart ; temp val for storing current index/order of "multi-volume" lzo archives

If Not FileExists(@ScriptDir & "\MstarUpgrade.bin") Then
	ConsoleWrite("[!] MstarUpgrade.bin not found in current folder" & @CRLF)
	Exit
EndIf

If FileExists(@ScriptDir & "\unpacked") Then
	ConsoleWrite("[!] Folder 'unpacked' already exists. Remove or rename it first." & @CRLF)
	Exit
	;DirRemove(@ScriptDir & "\unpacked", 1)
EndIf

ConsoleWrite("[i] MstarUpgrade.bin found" & @CRLF)
$hFile = FileOpen(@ScriptDir & "\MstarUpgrade.bin", $FO_BINARY)
ConsoleWrite("[#] Reading and parsing firmware bundle... please be patient!" & @CRLF)
$sFileContents = FileRead($hFile)
FileClose($hFile)

ripHeaderScript()
processChunkInfo()
extractChunks()
dumpInfo()
ConsoleWrite("[i] All done!" & @CRLF)

Func ripHeaderScript()
	Local $sFooterText = ("% <-this is end of file symbol" & @LF)
	Local $xFooterText = StringToBinary($sFooterText)
	$iPos = _BinaryInBin($sFileContents, $xFooterText) - 1 ;remember - first pos is 1 in autoit, but 0 in hex editors
	If $iPos < 1 Then
		ConsoleWrite("[!] Could not find header!" & @CRLF)
		Exit
	EndIf
	Local $hOutput = FileOpen(@ScriptDir & "\~bundle_script", $FO_OVERWRITE)
	FileWrite($hOutput, BinaryToString(_BinaryLeft($sFileContents, $iPos + StringLen($sFooterText))))
	FileClose($hOutput)
	$iLastPos = $iPos + StringLen($sFooterText)
EndFunc

Func processChunkInfo()
	ConsoleWrite("[#] Parsing chunks..." & @CRLF)
	Local $aFileLines
	_FileReadToArray(@ScriptDir & "\~bundle_script", $aFileLines)
	For $i = 1 To $aFileLines[0]
		$sMatchPattern = $FILE_PART_CMD & " "
		If _StringContains($aFileLines[$i], $sMatchPattern) Then
			$sLine = StringReplace($aFileLines[$i], $sMatchPattern, "")
			$aOffsetAndSize = StringSplit($sLine, " ")
			_ArrayAdd($aPartOffset, $aOffsetAndSize[1])
			_ArrayAdd($aPartLength, $aOffsetAndSize[2])
			; try and determine the label for this chunk
			If _StringContains($aFileLines[$i + 1], "mmc write.p " & $MEM_ADDR & " ") Then
				$sLine = StringReplace($aFileLines[$i + 1], "mmc write.p " & $MEM_ADDR & " ", "")
				$aSplit = StringSplit($sLine, " ")
				_ArrayAdd($aPartLabel, $aSplit[1])
				_ArrayAdd($aPartType, $PART_TYPE_RAW)
			ElseIf _StringContains($aFileLines[$i + 1], "store_secure_info ") Then
				$sLine = StringReplace($aFileLines[$i + 1], "store_secure_info ", "")
				$aSplit = StringSplit($sLine, " ")
				_ArrayAdd($aPartLabel, $aSplit[1])
				_ArrayAdd($aPartType, $PART_TYPE_SEC)
			ElseIf _StringContains($aFileLines[$i + 1], "mmc erase.p ") Then
				$sLine = StringReplace($aFileLines[$i + 1], "mmc erase.p ", "")
				$aSplit = StringSplit($sLine, " ")
				_ArrayAdd($aPartLabel, $aSplit[1])
				_ArrayAdd($aPartType, $PART_TYPE_RAW)
			ElseIf _StringContains($aFileLines[$i + 1], "store_nuttx_config ") Then
				$sLine = StringReplace($aFileLines[$i + 1], "store_nuttx_config ", "")
				$aSplit = StringSplit($sLine, " ")
				_ArrayAdd($aPartLabel, $aSplit[1])
				_ArrayAdd($aPartType, $PART_TYPE_NUTTX)
			ElseIf _StringContains($aFileLines[$i + 1], "mmc unlzo " & $MEM_ADDR & " ") Then
				; reset the lzo "volume index"
				$iChunkPart = 0
				$sLine = StringReplace($aFileLines[$i + 1], "mmc unlzo " & $MEM_ADDR & " ", "")
				$aSplit = StringSplit($sLine, " ")
				_ArrayAdd($aPartLabel, $aSplit[2] & "." & $iChunkPart)
				_ArrayAdd($aPartType, $PART_TYPE_LZO)
			ElseIf _StringContains($aFileLines[$i + 1], "mmc unlzo.cont " & $MEM_ADDR & " ") Then
				; increment the lzo "volume index"
				$iChunkPart += 1
				$sLine = StringReplace($aFileLines[$i + 1], "mmc unlzo.cont " & $MEM_ADDR & " ", "")
				$aSplit = StringSplit($sLine, " ")
				_ArrayAdd($aPartLabel, $aSplit[2] & "." & $iChunkPart)
				_ArrayAdd($aPartType, $PART_TYPE_LZO)
			ElseIf _StringContains($aFileLines[$i + 1], "mmc write.boot ") Then
				_ArrayAdd($aPartLabel, "misc")
				_ArrayAdd($aPartType, $PART_TYPE_MISC)
			Else
				ConsoleWrite(@CRLF)
				ConsoleWrite("    [!] Error - could not determine partition label/type for data chunk @ line " & $i & @CRLF)
				Exit
			EndIf
			; set the post-header padding if needed
			If $iPostHeaderPadding = 0 Then
				$iPostHeaderPadding = Dec($aOffsetAndSize[1]) - $iLastPos
				ConsoleWrite("    [i] Post-header padding = " & $iPostHeaderPadding & " bytes (" & _BinaryReverse(_BinaryFromInt16($iPostHeaderPadding)) & ")" & @CRLF)
			Else
				; set the post-partition padding
				$iPadding = (Dec($aOffsetAndSize[1]) - $iLastPos)
				ConsoleWrite(" (+ " & $iPadding & " bytes padding)" & @CRLF)
				_ArrayAdd($aPostChunkPadding, $iPadding)
			EndIf
			; update the last position for next run
			$iLastPos = Dec($aOffsetAndSize[1]) + Dec($aOffsetAndSize[2])
			ConsoleWrite("    [i] Chunk " & UBound($aPartLabel) & ": " & $aPartLabel[(UBound($aPartLabel) - 1)] & " = " & $aOffsetAndSize[2] & "@" & $aOffsetAndSize[1]) ; line feed added on next run (after padding print)
		EndIf
	Next
	; process the last-chunk padding

	Local $xMagicFooter = StringToBinary("����" & $MAGIC_FOOTER)
	$iPos = _BinaryInBin($sFileContents, $xMagicFooter, 1, $iLastPos) - 1 ;remember - first pos is 1 in autoit, but 0 in hex editors
	$iPos += 4; four bytes of dummy data to ensure we got the best match
	If $iPos < 1 Then
		ConsoleWrite(@CRLF & "[!] Could not find magic footer!" & @CRLF)
		Exit
	EndIf
	$iPadding = ($iPos - $iLastPos)
	ConsoleWrite(" (+ " & $iPadding & " bytes padding)" & @CRLF)
	_ArrayAdd($aPostChunkPadding, $iPadding)
	; skip-over the magic numbers
	$iPos += 8
	; grab the CRC32
	ConsoleWrite("[i] CRC32 (script) = ")
	$iCRC32_script = _BinaryReverse((BinaryMid($sFileContents, $iPos + 1, 4))) ; remember - autoit is 1-based byte offsets
	ConsoleWrite($iCRC32_script & @CRLF)
	; get the second CRC32, whatever it is
	$iCRC32_unknown = _BinaryReverse((BinaryMid($sFileContents, $iPos + 5, 4))) ; remember - autoit is 1-based byte offsets
	; get the footer command (or whatever it is)
	$sFooterCmd = BinaryMid($sFileContents, $iPos + 1 + 8)
	ConsoleWrite("[i] Footer command (raw binary for display purposes only) = " & $sFooterCmd & @CRLF)
EndFunc

Func extractChunks()
	DirCreate(@ScriptDir & "\unpacked")
	$iTotalChunks = UBound($aPartLabel)
	For $i = 1 To $iTotalChunks
		$sExtension = _getChunkExtensionByType($aPartType[$i - 1])
		$sFilename = $aPartLabel[($i - 1)] & $sExtension
		ConsoleWrite(@CR & "[#] Writing-out chunk " & $i & "/" & $iTotalChunks & " to " & $sFilename & "...             ")
		$hOutput = FileOpen(@ScriptDir & "\unpacked\" & $sFilename, $FO_OVERWRITE)
		$iStart = Dec($aPartOffset[$i-1]) + 1
		$iLength = Dec($aPartLength[$i-1])
		$xData = BinaryMid($sFileContents, $iStart, $iLength)
		FileWrite($hOutput, $xData)
		FileClose($hOutput) ; FileClose will flush buffers automatically
	Next
	ConsoleWrite(@CRLF)
EndFunc

Func dumpInfo()
	ConsoleWrite("[#] Moving header script..." & @CRLF)
	FileMove(@ScriptDir & "\~bundle_script", @ScriptDir & "\unpacked\~bundle_script", $FC_OVERWRITE)
	ConsoleWrite("[#] Writing-out bundle information..." & @CRLF)
	;FileWrite(@ScriptDir & "\unpacked\99_crc32", $iCRC32_script)
	IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "common", "crc32_script", $iCRC32_script)
	IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "common", "crc32_unknown", $iCRC32_unknown)
	;FileWrite(@ScriptDir & "\unpacked\99_footer", $sFooterCmd)
	IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "common", "footer_cmd", $sFooterCmd)
	;FileWrite(@ScriptDir & "\unpacked\99_headerpadding", $iPostHeaderPadding)
	IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "common", "script_padding", $iPostHeaderPadding)

	For $i = 1 To UBound($aPartLabel)
		; write out the padding info for each chunk
		; _FileWriteFromArray(@ScriptDir & "\unpacked\99_chunk-padding", $aPostChunkPadding)
		IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "chunk" & $i, "label", $aPartLabel[$i - 1])
		IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "chunk" & $i, "type", $aPartType[$i - 1])
		IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "chunk" & $i, "padding", $aPostChunkPadding[$i - 1])
		IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "chunk" & $i, "offset", $aPartOffset[$i - 1])
		IniWrite(@ScriptDir & "\unpacked\~bundle_info.ini", "chunk" & $i, "length", $aPartLength[$i - 1])
	Next
EndFunc
