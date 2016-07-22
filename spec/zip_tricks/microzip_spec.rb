require_relative '../spec_helper'
require_relative '../../testing/support'

describe ZipTricks::Microzip do
  class ByteReader < Struct.new(:io)
    def read_2b
      io.read(2).unpack('v').first
    end

    def read_2c
      io.read(2).unpack('CC').first
    end

    def read_4b
      io.read(4).unpack('V').first
    end

    def read_8b
      io.read(8).unpack('Q<').first
    end

    def read_n(n)
      io.read(n)
    end
  end

  class IOWrapper < ZipTricks::WriteAndTell
    def read(n)
      @io.read(n)
    end
  end

  it 'raises an exception if the filename is non-unique in the already existing set' do
    z = described_class.new
    z.add_local_file_header(io: StringIO.new, filename: 'foo.txt', crc32: 0, compressed_size: 0, uncompressed_size: 0, storage_mode: 0)
    expect {
      z.add_local_file_header(io: StringIO.new, filename: 'foo.txt', crc32: 0, compressed_size: 0, uncompressed_size: 0, storage_mode: 0)
    }.to raise_error(/already/)
  end

  it 'raises an exception if the filename contains backward slashes' do
    z = described_class.new
    expect {
      z.add_local_file_header(io: StringIO.new, filename: 'windows\not\welcome.txt',
        crc32: 0, compressed_size: 0, uncompressed_size: 0, storage_mode: 0)
    }.to raise_error(/UNIX/)
  end

  it 'raises an exception if the filename does not fit in 0xFFFF bytes' do
    longest_filename_in_the_universe = "x" * (0xFFFF + 1)
    z = described_class.new
    expect {
      z.add_local_file_header(io: StringIO.new, filename: longest_filename_in_the_universe,
        crc32: 0, compressed_size: 0, uncompressed_size: 0, storage_mode: 0)
    }.to raise_error(/is too long/)
  end

  describe '#add_local_file_header' do
    it 'writes out the local file header for an entry that fits into a standard ZIP' do
      buf = StringIO.new
      zip = described_class.new
      mtime = Time.utc(2016, 7, 17, 13, 48)
      zip.add_local_file_header(io: buf, filename: 'first-file.bin', crc32: 123, compressed_size: 8981,
        uncompressed_size: 90981, storage_mode: 8, mtime: mtime)

      buf.rewind
      br = ByteReader.new(buf)
      expect(br.read_4b).to eq(0x04034b50) # Signature
      expect(br.read_2b).to eq(20)         # Version needed to extract
      expect(br.read_2b).to eq(0)          # gp flags
      expect(br.read_2b).to eq(8)          # storage mode
      expect(br.read_2b).to eq(28160)      # DOS time
      expect(br.read_2b).to eq(18673)      # DOS date
      expect(br.read_4b).to eq(123)        # CRC32
      expect(br.read_4b).to eq(8981)       # compressed size
      expect(br.read_4b).to eq(90981)      # uncompressed size
      expect(br.read_2b).to eq('first-file.bin'.bytesize)      # byte length of the filename
      expect(br.read_2b).to be_zero        # size of extra fields
      expect(br.read_n('first-file.bin'.bytesize)).to eq('first-file.bin') # the filename
      expect(buf).to be_eof
    end

    it 'writes out the local file header for an entry with a UTF-8 filename, setting the proper GP flag bit' do
      buf = StringIO.new
      zip = described_class.new
      mtime = Time.utc(2016, 7, 17, 13, 48)
      zip.add_local_file_header(io: buf, filename: 'файл.bin', crc32: 123, compressed_size: 8981,
        uncompressed_size: 90981, storage_mode: 8, mtime: mtime)

      buf.rewind
      br = ByteReader.new(buf)
      br.read_4b # Signature
      br.read_2b # Version needed to extract
      expect(br.read_2b).to eq(2048)       # gp flags
    end

    it "correctly recognizes UTF-8 filenames even if they are tagged as ASCII" do
      name = 'файл.bin'
      name.force_encoding(Encoding::US_ASCII)

      buf = StringIO.new
      zip = described_class.new
      mtime = Time.utc(2016, 7, 17, 13, 48)
      zip.add_local_file_header(io: buf, filename: name, crc32: 123, compressed_size: 8981,
                                uncompressed_size: 90981, storage_mode: 8, mtime: mtime)

      buf.rewind
      br = ByteReader.new(buf)
      br.read_4b # Signature
      br.read_2b # Version needed to extract
      expect(br.read_2b).to eq(2048)       # gp flags
    end

    it 'writes out the local file header for an entry with a filename with diacritics, setting the proper GP flag bit' do
      buf = StringIO.new
      zip = described_class.new
      mtime = Time.utc(2016, 7, 17, 13, 48)
      zip.add_local_file_header(io: buf, filename: 'Kungälv', crc32: 123, compressed_size: 8981,
        uncompressed_size: 90981, storage_mode: 8, mtime: mtime)

      buf.rewind
      br = ByteReader.new(buf)
      br.read_4b # Signature
      br.read_2b # Version needed to extract
      expect(br.read_2b).to eq(2048)       # gp flags
      br.read_2b
      br.read_2b
      br.read_2b
      br.read_4b
      br.read_4b
      br.read_4b
      br.read_2b
      br.read_2b
      filename_readback = br.read_n('Kungälv'.bytesize)
      expect(filename_readback.force_encoding(Encoding::UTF_8)).to eq('Kungälv')
    end

    it 'writes out the local file header for an entry that requires Zip64 based on its compressed size _only_' do
      buf = StringIO.new
      zip = described_class.new
      mtime = Time.utc(2016, 7, 17, 13, 48)
      zip.add_local_file_header(io: buf, filename: 'first-file.bin', crc32: 123, compressed_size: (0xFFFFFFFF + 1),
        uncompressed_size: 90981, storage_mode: 8, mtime: mtime)

      buf.rewind
      br = ByteReader.new(buf)
      expect(br.read_4b).to eq(0x04034b50) # Signature
      expect(br.read_2b).to eq(45)         # Version needed to extract (require Zip64 support)
      expect(br.read_2b).to eq(0)          # gp flags
      expect(br.read_2b).to eq(8)          # storage mode
      expect(br.read_2b).to eq(28160)      # DOS time
      expect(br.read_2b).to eq(18673)      # DOS date
      expect(br.read_4b).to eq(123)        # CRC32
      expect(br.read_4b).to eq(0xFFFFFFFF) # compressed size (blanked out)
      expect(br.read_4b).to eq(0xFFFFFFFF) # uncompressed size (blanked out)
      expect(br.read_2b).to eq('first-file.bin'.bytesize)      # byte length of the filename
      expect(br.read_2b).to eq(20)         # size of extra fields
      expect(br.read_n('first-file.bin'.bytesize)).to eq('first-file.bin') # the filename
      expect(br.read_2b).to eq(1)              # Zip64 extra field signature
      expect(br.read_2b).to eq(16)             # Size of the Zip64 extra field
      expect(br.read_8b).to eq(90981)          # True compressed size
      expect(br.read_8b).to eq(0xFFFFFFFF + 1) # True uncompressed size
      expect(buf).to be_eof
    end

    it 'writes out the local file header for an entry that requires Zip64 based on its uncompressed size _only_' do
      buf = StringIO.new
      zip = described_class.new
      mtime = Time.utc(2016, 7, 17, 13, 48)
      zip.add_local_file_header(io: buf, filename: 'first-file.bin', crc32: 123, compressed_size: 90981,
        uncompressed_size: (0xFFFFFFFF + 1), storage_mode: 8, mtime: mtime)

      buf.rewind
      br = ByteReader.new(buf)
      expect(br.read_4b).to eq(0x04034b50) # Signature
      expect(br.read_2b).to eq(45)         # Version needed to extract (require Zip64 support)
      expect(br.read_2b).to eq(0)          # gp flags
      expect(br.read_2b).to eq(8)          # storage mode
      expect(br.read_2b).to eq(28160)      # DOS time
      expect(br.read_2b).to eq(18673)      # DOS date
      expect(br.read_4b).to eq(123)        # CRC32
      expect(br.read_4b).to eq(0xFFFFFFFF) # compressed size (blanked out)
      expect(br.read_4b).to eq(0xFFFFFFFF) # uncompressed size (blanked out)
      expect(br.read_2b).to eq('first-file.bin'.bytesize)      # byte length of the filename
      expect(br.read_2b).to eq(20)         # size of extra fields
      expect(br.read_n('first-file.bin'.bytesize)).to eq('first-file.bin') # the filename
      expect(br.read_2b).to eq(1)              # Zip64 extra field signature
      expect(br.read_2b).to eq(16)             # Size of the Zip64 extra field
      expect(br.read_8b).to eq(0xFFFFFFFF + 1) # True uncompressed size
      expect(br.read_8b).to eq(90981)          # True compressed size
      expect(buf).to be_eof
    end

    it 'does not write out the Zip64 extra if the position in the destination IO is beyond the Zip64 size limit' do
      buf = StringIO.new
      zip = described_class.new
      mtime = Time.utc(2016, 7, 17, 13, 48)
      expect(buf).to receive(:tell).and_return(0xFFFFFFFF + 1)
      zip.add_local_file_header(io: buf, filename: 'first-file.bin', crc32: 123, compressed_size: 123,
        uncompressed_size: 456, storage_mode: 8, mtime: mtime)

      buf.rewind
      br = ByteReader.new(buf)
      expect(br.read_4b).to eq(0x04034b50) # Signature
      expect(br.read_2b).to eq(20)         # Version needed to extract (require Zip64 support)
      br.read_2b
      br.read_2b
      br.read_2b
      br.read_2b
      br.read_4b
      br.read_4b
      br.read_4b
      br.read_2b
      expect(br.read_2b).to be_zero
    end
  end

  describe '#write_central_directory' do
    it 'writes the central directory and makes it a valid one even if there were no files' do
      buf = StringIO.new

      zip = described_class.new
      zip.write_central_directory(buf)

      buf.rewind
      br = ByteReader.new(buf)
      expect(br.read_4b).to eq(0x06054b50) # EOCD signature
      expect(br.read_2b).to eq(0)          # disk number
      expect(br.read_2b).to eq(0)          # disk number of the disk containing EOCD
      expect(br.read_2b).to eq(0)          # num files in the central directory of this disk
      expect(br.read_2b).to eq(0)          # num files in the central directories of all disks
      expect(br.read_4b).to eq(0)          # central directorys size
      expect(br.read_4b).to eq(0)          # offset of start of central directory from the beginning of the disk
      expect(br.read_2b).to eq(0)          # ZIP file comment length
      expect(buf).to be_eof
    end

    it 'writes the central directory for 2 files' do
      zip = described_class.new

      mtime = Time.utc(2016, 7, 17, 13, 48)

      buf = StringIO.new
      zip.add_local_file_header(io: buf, filename: 'first-file.bin', crc32: 123, compressed_size: 5,
        uncompressed_size: 8, storage_mode: 8, mtime: mtime)
      buf << Random.new.bytes(5)
      zip.add_local_file_header(io: buf, filename: 'second-file.txt', crc32: 546, compressed_size: 9,
        uncompressed_size: 9, storage_mode: 0, mtime: mtime)
      buf << Random.new.bytes(5)

      central_dir_offset = buf.tell
      zip.write_central_directory(buf)

      # Seek to where the central directory begins
      buf.rewind
      buf.seek(central_dir_offset)

      br = ByteReader.new(buf)

      # Central directory entry for the first file
      expect(br.read_4b).to eq(0x02014b50) # Central directory entry sig
      expect(br.read_2b).to eq(820)        # version made by
      expect(br.read_2b).to eq(20)         # version need to extract
      expect(br.read_2b).to eq(0)          # general purpose bit flag
      expect(br.read_2b).to eq(8)          # compression method (deflated here)
      expect(br.read_2b).to eq(28160)      # last mod file time
      expect(br.read_2b).to eq(18673)      # last mod file date
      expect(br.read_4b).to eq(123)        # crc32
      expect(br.read_4b).to eq(5)          # compressed size
      expect(br.read_4b).to eq(8)          # uncompressed size
      expect(br.read_2b).to eq(14)         # filename length
      expect(br.read_2b).to eq(0)          # extra field length
      expect(br.read_2b).to eq(0)          # file comment
      expect(br.read_2b).to eq(0)          # disk number, must be blanked to the maximum value because of The Unarchiver bug
      expect(br.read_2b).to eq(0)          # internal file attributes
      expect(br.read_4b).to eq(2175008768) # external file attributes
      expect(br.read_4b).to eq(0)          # relative offset of local header
      expect(br.read_n(14)).to eq('first-file.bin') # the filename
      
      # Central directory entry for the second file
      expect(br.read_4b).to eq(0x02014b50) # Central directory entry sig
      expect(br.read_2b).to eq(820)        # version made by
      expect(br.read_2b).to eq(20)         # version need to extract
      expect(br.read_2b).to eq(0)          # general purpose bit flag
      expect(br.read_2b).to eq(0)          # compression method (stored here)
      expect(br.read_2b).to eq(28160)      # last mod file time
      expect(br.read_2b).to eq(18673)      # last mod file date
      expect(br.read_4b).to eq(546)        # crc32
      expect(br.read_4b).to eq(9)          # compressed size
      expect(br.read_4b).to eq(9)          # uncompressed size
      expect(br.read_2b).to eq('second-file.bin'.bytesize)         # filename length
      expect(br.read_2b).to eq(0)          # extra field length
      expect(br.read_2b).to eq(0)          # file comment
      expect(br.read_2b).to eq(0)          # disk number, must be blanked to the maximum value because of The Unarchiver bug
      expect(br.read_2b).to eq(0)          # internal file attributes
      expect(br.read_4b).to eq(2175008768) # external file attributes
      expect(br.read_4b).to eq(49)         # relative offset of local header
      expect(br.read_n('second-file.txt'.bytesize)).to eq('second-file.txt') # the filename
      
      expect(br.read_4b).to eq(0x06054b50) # end of central dir signature
      br.read_2b
      br.read_2b
      br.read_2b
      br.read_2b
      br.read_4b
      br.read_4b
      br.read_2b

      expect(buf).to be_eof
    end

    it 'writes the central directory for 1 file that is larger than 4GB' do
      zip   = described_class.new
      buf   = StringIO.new
      big   = 0xFFFFFFFF + 2048
      mtime = Time.utc(2016, 7, 17, 13, 48)

      zip.add_local_file_header(io: buf, filename: 'big-file.bin', crc32: 12345, compressed_size: big,
                                uncompressed_size: big, storage_mode: 0, mtime: mtime)

      central_dir_offset = buf.tell

      zip.write_central_directory(buf)

      # Seek to where the central directory begins
      buf.rewind
      buf.seek(central_dir_offset)

      br = ByteReader.new(buf)

      # Standard central directory entry (similar to the local file header)
      expect(br.read_4b).to eq(0x02014b50)  # Central directory entry sig
      expect(br.read_2b).to eq(820)         # version made by
      expect(br.read_2b).to eq(45)          # version need to extract (45 for Zip64)
      expect(br.read_2b).to eq(0)           # general purpose bit flag
      expect(br.read_2b).to eq(0)           # compression method (stored here)
      expect(br.read_2b).to eq(28160)       # last mod file time
      expect(br.read_2b).to eq(18673)       # last mod file date
      expect(br.read_4b).to eq(12345)       # crc32
      expect(br.read_4b).to eq(0xFFFFFFFF)  # compressed size
      expect(br.read_4b).to eq(0xFFFFFFFF)  # uncompressed size
      expect(br.read_2b).to eq(12)          # filename length
      expect(br.read_2b).to eq(32)          # extra field length (we store the Zip64 extra field for this file)
      expect(br.read_2b).to eq(0)           # file comment
      expect(br.read_2b).to eq(0xFFFF)      # disk number, must be blanked to the maximum value because of The Unarchiver bug
      expect(br.read_2b).to eq(0)           # internal file attributes
      expect(br.read_4b).to eq(2175008768)  # external file attributes
      expect(br.read_4b).to eq(0xFFFFFFFF)  # relative offset of local header
      expect(br.read_n(12)).to eq('big-file.bin') # the filename

      # Zip64 extra field
      expect(br.read_2b).to eq(0x0001) # Tag for the "extra" block
      expect(br.read_2b).to eq(28) # Size of this "extra" block. For us it will always be 28
      expect(br.read_8b).to eq(big) # Original uncompressed file size
      expect(br.read_8b).to eq(big) # Original compressed file size
      expect(br.read_8b).to eq(0) # Offset of local header record
      expect(br.read_4b).to eq(0) # Number of the disk on which this file starts
    end

    it 'writes the central directory for 2 files which, together, make the central directory start beyound the 4GB threshold' do
      zip   = described_class.new
      raw_buf = StringIO.new
      
      zip_write_buf   = IOWrapper.new(raw_buf)
      big1  = 0xFFFFFFFF/2 + 512
      big2  = 0xFFFFFFFF/2 + 1024
      mtime = Time.utc(2016, 7, 17, 13, 48)

      zip.add_local_file_header(io: zip_write_buf, filename: 'first-big-file.bin', crc32: 12345, compressed_size: big1,
                                uncompressed_size: big1, storage_mode: 0, mtime: mtime)
      zip_write_buf.advance_position_by(big1)
      
      zip.add_local_file_header(io: zip_write_buf, filename: 'second-big-file.bin', crc32: 54321, compressed_size: big2,
                                uncompressed_size: big2, storage_mode: 0, mtime: mtime)
      zip_write_buf.advance_position_by(big2)

      fake_central_dir_offset   = zip_write_buf.tell # Grab the position in the underlying buffer
      actual_central_dir_offset = raw_buf.tell # Grab the position in the underlying buffer

      zip.write_central_directory(zip_write_buf)

      # Seek to where the central directory begins
      raw_buf.seek(actual_central_dir_offset, IO::SEEK_SET)

      br = ByteReader.new(raw_buf)

      # Standard central directory entry (similar to the local file header)
      expect(br.read_4b).to eq(0x02014b50)  # Central directory entry sig
      expect(br.read_2b).to eq(820)         # version made by
      expect(br.read_2b).to eq(20)          # version need to extract (45 for Zip64)
      expect(br.read_2b).to eq(0)           # general purpose bit flag
      expect(br.read_2b).to eq(0)           # compression method (stored here)
      expect(br.read_2b).to eq(28160)       # last mod file time
      expect(br.read_2b).to eq(18673)       # last mod file date
      expect(br.read_4b).to eq(12345)       # crc32
      expect(br.read_4b).to eq(2147484159)  # compressed size
      expect(br.read_4b).to eq(2147484159)  # uncompressed size
      expect(br.read_2b).to eq(18)          # filename length
      expect(br.read_2b).to eq(0)           # extra field length
      expect(br.read_2b).to eq(0)           # file comment length
      expect(br.read_2b).to eq(0)           # disk number, must be blanked to the maximum value because of The Unarchiver bug
      expect(br.read_2b).to eq(0)           # internal file attributes
      expect(br.read_4b).to eq(2175008768)  # external file attributes
      expect(br.read_4b).to eq(0)           # relative offset of local header
      expect(br.read_n(18)).to eq("first-big-file.bin") # the filename
      
      # Standard central directory entry (similar to the local file header)
      expect(br.read_4b).to eq(0x02014b50)  # Central directory entry sig
      expect(br.read_2b).to eq(820)         # version made by
      expect(br.read_2b).to eq(20)          # version need to extract (45 for Zip64)
      expect(br.read_2b).to eq(0)           # general purpose bit flag
      expect(br.read_2b).to eq(0)           # compression method (stored here)
      expect(br.read_2b).to eq(28160)       # last mod file time
      expect(br.read_2b).to eq(18673)       # last mod file date
      expect(br.read_4b).to eq(54321)       # crc32
      expect(br.read_4b).to eq(2147484671)  # compressed size
      expect(br.read_4b).to eq(2147484671)  # uncompressed size
      expect(br.read_2b).to eq(19)          # filename length
      expect(br.read_2b).to eq(0)           # extra field length
      expect(br.read_2b).to eq(0)           # file comment length
      expect(br.read_2b).to eq(0)           # disk number, must be blanked to the maximum value because of The Unarchiver bug
      expect(br.read_2b).to eq(0)           # internal file attributes
      expect(br.read_4b).to eq(2175008768)  # external file attributes
      expect(br.read_4b).to eq(2147484207)  # relative offset of local header
      expect(br.read_n(19)).to eq('second-big-file.bin') # the filename
      
      # zip64 specific values for a whole central directory
      expect(br.read_4b).to eq(0x06064b50) # zip64 end of central dir signature
      expect(br.read_8b).to eq(44) # size of zip64 end of central directory record
      expect(br.read_2b).to eq(820) # version made by
      expect(br.read_2b).to eq(45) # version need to extract
      expect(br.read_4b).to eq(0) # number of this disk
      expect(br.read_4b).to eq(0) # another number related to disk
      expect(br.read_8b).to eq(2) # total number of entries in the central directory on this disk
      expect(br.read_8b).to eq(2) # total number of entries in the central directory
      expect(br.read_8b).to eq(129) # size of central directory
      expect(br.read_8b).to eq(4294968927) # starting disk number
      expect(br.read_4b).to eq(0x07064b50) # zip64 end of central dir locator signature
      expect(br.read_4b).to eq(0) # number of disk ...
      expect(br.read_8b).to eq(4294969056) # relative offset zip64
      expect(br.read_4b).to eq(1) # total number of disks
    end
  end
end
