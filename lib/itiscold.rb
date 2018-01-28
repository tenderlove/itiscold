require 'termios'
require 'fcntl'
require 'webrick'
require 'json'
require 'uart'

class Itiscold
  VERSION = '1.0.1'

  def self.open filename, speed = 115200
    f = UART.open filename, speed

    temp = new f

    # Try reading the version a few times before giving up
    temp.flush
    temp
  end

  def initialize tty
    @tty = tty
  end

  DeviceInfo = Struct.new :station_number,
    :model_number,
    :sample_interval,   # in seconds
    :upper_limit,
    :lower_limit,
    :last_online,
    :work_status,
    :start_time,
    :stop_button,
    :sample_count,
    :current_time,
    :user_info,
    :number,
    :delay_time,        # in seconds
    :tone_set,
    :alarm,
    :temp_unit,
    :temp_calibration,
    :new_station_number

  def device_info
    val = retry_comm(1) do
      @tty.write with_checksum([0xCC, 0x00, 0x06, 0x00]).pack('C5')
      @tty.read 160
    end
    _,            # C set number
    station_no,   # C station number
    _,            # C
    model_no,     # C model number
    _,            # C
    rec_int_h,    # C record interval hour
    rec_int_m,    # C record interval min
    rec_int_s,    # C record interval sec
    upper_limit,  # n upper limit
    lower_limit,  # s> lower limit
    last_online,  # A7 (datetime)
    ws,           # C work status
    start_time,   # A7 (datetime)
    sb,           # C stop button
    _,            # C
    sample_count, # n number of records
    current_time, # A7 (datetime)
    user_info,    # A100
    number,       # A10
    delaytime,    # C
    tone_set,     # C
    alrm,         # C
    tmp_unit,     # C
    temp_calib,   # C temp calibration
    _,            # A6 padding
    check,        # C padding
    = val.unpack('C8ns>A7CA7CCnA7A100A10C5A6C')
    check_checksum check, checksum(val.bytes.first(val.bytesize - 1))
    DeviceInfo.new station_no, model_no,
      (rec_int_h * 3600 + rec_int_m * 60 + rec_int_s),
      upper_limit / 10.0, lower_limit / 10.0, unpack_datetime(last_online),
      work_status(ws), unpack_datetime(start_time), allowed_decode(sb),
      sample_count, unpack_datetime(current_time), user_info, number,
      delay_time_decode(delaytime), allowed_decode(tone_set), alrm, temp_unit_decode(tmp_unit),
      temp_calib / 10.0
  end

  def device_params= values
    data = [
      0x33, # C
      values.station_number, # C
      0x05, 0x00,            # CC
    ] + split_time(values.sample_interval) + # CCC
    [
      (values.upper_limit * 10).to_i, # n
      (values.lower_limit * 10).to_i, # s>
      values.new_station_number || values.station_number, # C
      allowed_encode(values.stop_button), # C
      delay_time_encode(values.delay_time), # C
      allowed_encode(values.tone_set), # C
      values.alarm, # C
      temp_unit_encode(values.temp_unit), # C
      (values.temp_calibration * 10).to_i, # C
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00 # C6
    ]
    retry_comm(1) do
      @tty.write with_checksum(data).pack('CCCCCCCns>CCCCCCCC6C')
      @tty.read 3
    end
  end

  def clear_data!
    self.device_params = device_info
  end

  def set_device_number station_number, dev_number
    str = dev_number.bytes.first(10)
    str.concat([0x00] * (10 - str.length))
    data = [ 0x33, station_number, 0x0b, 0x00 ] + str

    retry_comm(1) do
      @tty.write with_checksum(data).pack("C#{data.length + 1}")
      @tty.read 3
    end
  end

  def set_user_info info, station_number = device_info.station_number
    str = info.bytes.first(100)
    str.concat([0x00] * (100 - str.length))
    data = [ 0x33, station_number, 0x09, 0x00 ] + str

    retry_comm(1) do
      @tty.write with_checksum(data).pack("C#{data.length + 1}")
      @tty.read 3
    end
  end

  def set_device_time! time = Time.now, station_number = device_info.station_number
    data = [0x33, station_number, 0x07, 0x00] + encode_datetime(time)

    retry_comm(1) do
      @tty.write with_checksum(data).pack("C4nC6")
      @tty.read 3
    end
  end

  DataHeader = Struct.new :sample_count, :start_time

  def data_header station
    buf = retry_comm(1) do
      @tty.write with_checksum([0x33, station, 0x1, 0x0]).pack('C5')
      @tty.read 11
    end
    _, sample_count, start_time, check = buf.unpack 'CnA7C'

    check_checksum check, checksum(buf.bytes.first(buf.bytesize - 1))

    DataHeader.new sample_count, unpack_datetime(start_time)
  end

  def data_body station, page
    buf = retry_comm(1) do
      @tty.write with_checksum([0x33, station, 0x2, page]).pack('C5')
      @tty.read
    end
    temps = buf.unpack("Cn#{(buf.bytesize - 2) / 2}C")
    temps.shift # header
    temps.pop   # checksum
    temps.map { |t| t / 10.0 }
  end

  def samples
    info    = device_info
    header  = data_header info.station_number
    records = header.sample_count
    page    = 0
    list    = []
    while records > 0
      samples = data_body info.station_number, page
      records -= samples.length
      list    += samples
      page    += 1
    end
    st = header.start_time
    list.map.with_index { |v, i| [st + (i * info.sample_interval), v] }
  end

  def flush
    Termios.tcflush @tty, Termios::TCIOFLUSH
  end

  private

  def split_time time_s
    h = time_s / 3600
    time_s -= (h * 3600)
    m = time_s / 60
    time_s -= (m * 60)
    [h, m, time_s]
  end

  def retry_comm times
    x = nil
    loop do
      x = yield
      break if x || times == 0
      flush
      times -= 1
    end
    x
  end

  def temp_unit_decode u
    case u
    when 0x13 then 'F'
    when 0x31 then 'C'
    else
      raise u.to_s
    end
  end

  def temp_unit_encode u
    case u
    when 'F' then 0x13
    when 'C' then 0x31
    else
      raise u.to_s
    end
  end

  def delay_time_decode dt
    case dt
    when 0x00 then 0
    when 0x01 then 30 * 60  # 30min in sec
    when 0x10 then 60 * 60  # 60min in sec
    when 0x11 then 90 * 60  # 90min in sec
    when 0x20 then 120 * 60 # 120min in sec
    when 0x21 then 150 * 60 # 150min in sec
    end
  end

  def delay_time_encode dt
    case dt
    when 0        then 0x00
    when 30 * 60  then 0x01 # 30min in sec
    when 60 * 60  then 0x10 # 60min in sec
    when 90 * 60  then 0x11 # 90min in sec
    when 120 * 60 then 0x20 # 120min in sec
    when 150 * 60 then 0x21 # 150min in sec
    end
  end

  def allowed_decode sb
    case sb
    when 0x13 then :permit
    when 0x31 then :prohibit
    else
      raise sb.to_s
    end
  end

  def allowed_encode sb
    case sb
    when :permit then 0x13
    when :prohibit then 0x31
    else
      raise sb.to_s
    end
  end

  def work_status ws
    case ws
    when 0 then :not_started
    when 1 then :start
    when 2 then :stop
    when 3 then :unknown
    end
  end

  def check_checksum expected, actual
    raise "invalid checksum #{expected} == #{actual}" unless expected == actual
  end

  NULL_DATE = [65535, 255, 255, 255, 255, 255].pack('nC5')

  def unpack_datetime bytes
    return if bytes == NULL_DATE
    Time.new(*bytes.unpack('nC5'))
  end

  def encode_datetime time
    [time.year, time.month, time.day, time.hour, time.min, time.sec]
  end

  def with_checksum list
    list + [checksum(list)]
  end

  def checksum list
    list.inject(:+) % 256
  end

  module WebServer
    class TTYServlet < WEBrick::HTTPServlet::AbstractServlet
      def initialize server, tty, mutex
        super server
        @tty   = tty
        @mutex = mutex
      end
    end

    class InfoServlet < TTYServlet
      def do_GET request, response
        response.status = 200
        response['Content-Type'] = 'text/json'
        @mutex.synchronize do
          json = JSON.dump(@tty.device_info.to_h)
          response.body = json
        end
      end
    end

    class SampleServlet < TTYServlet
      def do_GET request, response
        response.status = 200
        response['Content-Type'] = 'text/json'
        @mutex.synchronize do
          response.body = JSON.dump @tty.samples.map { |s|
            { time: s.first.iso8601, temp: s.last }
          }
        end
      end
    end

    def self.start tty
      root = File.expand_path(File.join File.dirname(__FILE__), 'itiscold', 'public')
      mutex  = Mutex.new
      temp = Itiscold.open tty
      server = WEBrick::HTTPServer.new(:Port => 8000, :DocumentRoot => root)
      server.mount "/samples", SampleServlet, temp, mutex
      server.mount "/info", InfoServlet, temp, mutex
      trap "INT" do server.shutdown end
      server.start
    end
  end
end
