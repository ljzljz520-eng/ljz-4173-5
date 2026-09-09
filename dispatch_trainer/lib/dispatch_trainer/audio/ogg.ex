defmodule DispatchTrainer.Audio.Ogg do
  @moduledoc """
  Ogg/Opus 容器封装与解析(RFC 3533 / RFC 7845)。

  用于把通话中的 Opus 包持久化为录音文件, 以及脱敏导出时
  按时间段替换静音后重新封装。每个音频包独占一个 Ogg 页,
  granule 按 48kHz 采样数累计。
  """

  import Bitwise

  @serial 0x4454_4352
  @version 0
  @sample_rate 48_000

  # Ogg CRC32: 多项式 0x04C11DB7, 初值 0, 不反射, 不异或输出
  @crc_table (
               for i <- 0..255 do
                 r = i <<< 24

                 r =
                   Enum.reduce(1..8, r, fn _, acc ->
                     if (acc &&& 0x8000_0000) != 0 do
                       bxor(acc <<< 1, 0x04C11DB7) &&& 0xFFFFFFFF
                     else
                       acc <<< 1 &&& 0xFFFFFFFF
                     end
                   end)

                 r
               end
               |> List.to_tuple()
             )

  defstruct packets: [], duration_ms: 0

  @doc "Ogg CRC32。"
  def crc32(data), do: do_crc(data, 0)

  defp do_crc(<<>>, crc), do: crc

  defp do_crc(<<byte, rest::binary>>, crc) do
    idx = bxor(crc >>> 24, byte) &&& 0xFF
    do_crc(rest, bxor(crc <<< 8 &&& 0xFFFFFFFF, elem(@crc_table, idx)))
  end

  @doc "Opus 头页内容(OpusHead)。"
  def opus_head(channels \\ 1) do
    pre_skip = 0

    <<"OpusHead", 1, channels, pre_skip::little-16, @sample_rate::little-32, 0::little-16, 0>>
  end

  @doc "Opus 标签页内容(OpusTags)。"
  def opus_tags(vendor \\ "dispatch_trainer") do
    <<"OpusTags", byte_size(vendor)::little-32, vendor::binary, 0::little-32>>
  end

  @doc """
  将 Opus 包列表封装为 Ogg 二进制。

  `frame_duration_ms` 为每包帧时长(默认 20ms), 用于计算 granule。
  """
  def mux(packets, opts \\ []) when is_list(packets) do
    frame_ms = Keyword.get(opts, :frame_duration_ms, 20)
    samples_per_packet = round(frame_ms * @sample_rate / 1000)

    head_page = build_page(0x02, 0, 0, [opus_head()])
    tags_page = build_page(0x00, 0, 1, [opus_tags()])

    audio_pages =
      packets
      |> Enum.with_index()
      |> Enum.map(fn {packet, idx} ->
        granule = (idx + 1) * samples_per_packet
        header_type = if idx == length(packets) - 1, do: 0x04, else: 0x00
        build_page(header_type, granule, idx + 2, [packet])
      end)

    IO.iodata_to_binary([head_page, tags_page | audio_pages])
  end

  @doc """
  解析 Ogg 二进制, 返回 {:ok, %{packets: [...], duration_ms: ms}}。

  跳过 OpusHead/OpusTags 页; 校验每页 CRC, 损坏时返回 {:error, :bad_crc}。
  """
  def demux(binary) when is_binary(binary) do
    with {:ok, pages} <- parse_pages(binary, []) do
      packets =
        pages
        |> Enum.flat_map(fn {_type, _granule, segments} -> assemble_packets(segments) end)
        |> Enum.reject(fn pkt ->
          String.starts_with?(pkt, "OpusHead") or String.starts_with?(pkt, "OpusTags")
        end)

      last_granule =
        pages
        |> Enum.map(fn {_type, granule, _segments} -> granule end)
        |> Enum.max(fn -> 0 end)

      {:ok, %{packets: packets, duration_ms: div(last_granule * 1000, @sample_rate)}}
    end
  end

  # 将一页的段表数据组装为包(段长 255 表示延续)
  defp assemble_packets({seg_table, data}) do
    segs = for <<len <- seg_table>>, do: len
    {packets, _current, _rest} =
      Enum.reduce(segs, {[], <<>>, data}, fn len, {packets, current, rest} ->
        <<chunk::binary-size(len), tail::binary>> = rest
        current = current <> chunk

        if len < 255 do
          {[current | packets], <<>>, tail}
        else
          {packets, current, tail}
        end
      end)

    Enum.reverse(packets)
  end

  defp parse_pages(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_pages(
         <<"OggS", @version, header_type, granule::little-64, serial::little-32, seq::little-32,
           crc::little-32, num_segments, rest::binary>>,
         acc
       ) do
    with <<seg_table::binary-size(num_segments), tail::binary>> <- rest,
         data_len = seg_table |> :binary.bin_to_list() |> Enum.sum(),
         <<data::binary-size(data_len), tail::binary>> <- tail do
      # CRC 覆盖整页(含页序号), 计算时 CRC 字段置零
      zeroed_crc_page =
        <<"OggS", @version, header_type, granule::little-64, serial::little-32, seq::little-32,
          0::32, num_segments, seg_table::binary, data::binary>>

      if crc32(zeroed_crc_page) == crc do
        parse_pages(tail, [{header_type, granule, {seg_table, data}} | acc])
      else
        {:error, :bad_crc}
      end
    else
      _ -> {:error, :truncated}
    end
  end

  defp parse_pages(_, _), do: {:error, :bad_capture_pattern}

  @doc "构造单个 Ogg 页。payloads 为包列表, 自动处理 255 字节分段。"
  def build_page(header_type, granule, page_seq, payloads, serial \\ @serial) do
    {seg_table, data} =
      Enum.map_reduce(payloads, <<>>, fn payload, acc ->
        len = byte_size(payload)
        segs = List.duplicate(255, div(len, 255)) ++ [rem(len, 255)]
        {segs, acc <> payload}
      end)

    seg_table_binary = seg_table |> List.flatten() |> :binary.list_to_bin()
    num_segments = byte_size(seg_table_binary)

    header =
      <<"OggS", @version, header_type, granule::little-64, serial::little-32,
        page_seq::little-32, 0::32, num_segments, seg_table_binary::binary>>

    crc = crc32(header <> data)

    <<binary_part(header, 0, 22)::binary, crc::little-32,
      binary_part(header, 26, byte_size(header) - 26)::binary, data::binary>>
  end
end
