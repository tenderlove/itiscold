require 'termios'
require 'fcntl'

class Itiscold
  VERSION = '1.0.0'

  class TTY
    include Termios

    def self.open filename, speed, mode
      if mode =~ /^(\d)(\w)(\d)$/
        t.data_bits = $1.to_i
        t.stop_bits = $3.to_i
        t.parity = { 'N' => :none, 'E' => :even, 'O' => :odd }[$2]
        t.speed = speed
        t.read_timeout = 5
        t.reading = true
        t.update!
      end
    end

    def self.data_bits t, val
      t.cflag &= ~CSIZE               # clear previous values
      t.cflag |= const_get("CS#{val}") # Set the data bits
      t
    end

    def self.stop_bits t, val
      case val
      when 1 then t.cflag &= ~CSTOPB
      when 2 then t.cflag |= CSTOPB
      else
        raise
      end
      t
    end

    def self.parity t, val
      case val
      when :none
        t.cflag &= ~PARENB
      when :even
        t.cflag |= PARENB  # Enable parity
        t.cflag &= ~PARODD # Make it not odd
      when :odd
        t.cflag |= PARENB  # Enable parity
        t.cflag |= PARODD  # Make it odd
      else
        raise
      end
      t
    end

    def self.speed t, speed
      t.ispeed = const_get("B#{speed}")
      t.ospeed = const_get("B#{speed}")
      t
    end

    def self.read_timeout t, val
      t.cc[VTIME] = val
      t.cc[VMIN] = 0
      t
    end

    def self.reading t
      t.cflag |= CLOCAL | CREAD
      t
    end
  end

  def self.open filename, speed = 115200
    f = File.open filename, File::RDWR|Fcntl::O_NOCTTY|Fcntl::O_NDELAY
    f.sync = true

    # enable blocking reads, otherwise read timeout won't work
    f.fcntl Fcntl::F_SETFL, f.fcntl(Fcntl::F_GETFL, 0) & ~Fcntl::O_NONBLOCK

    t = Termios.tcgetattr f
    t = TTY.data_bits    t, 8
    t = TTY.stop_bits    t, 1
    t = TTY.parity       t, :none
    t = TTY.speed        t, speed
    t = TTY.read_timeout t, 5
    t = TTY.reading      t

    Termios.tcsetattr f, Termios::TCSANOW, t
    Termios.tcflush f, Termios::TCIOFLUSH

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
    :record_interval,   # in seconds
    :upper_limit,
    :lower_limit,
    :last_online,
    :work_status,
    :start_time,
    :stop_button,
    :record_count,
    :current_time,
    :user_info,
    :number,
    :delay_time,        # in seconds
    :tone_set,
    :alarm,
    :temp_unit,
    :temp_calibration

  def device_info
    @tty.write with_checksum([0xCC, 0x00, 0x06, 0x00]).pack('C5')
    val = @tty.read 160
    _,            # C set number
    station_no,   # C station number
    _,            # C
    model_no,     # C model number
    _,            # C
    rec_int_h,    # C record interval hour
    rec_int_m,    # C record interval min
    rec_int_s,    # C record interval sec
    upper_limit,  # n upper limit
    lower_limit,  # n lower limit
    last_online,  # A7 (datetime)
    ws,           # C work status
    start_time,   # A7 (datetime)
    sb,           # C stop button
    _,            # C
    record_count, # n number of records
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
    = val.unpack('C8n2A7CA7CCnA7A100A10C5A6C')
    check_checksum check, checksum(val.bytes.first(val.bytesize - 1))
    DeviceInfo.new station_no, model_no,
      (rec_int_h * 3600 + rec_int_m * 60 + rec_int_s),
      upper_limit / 10.0, lower_limit / 10.0, unpack_datetime(last_online),
      work_status(ws), unpack_datetime(start_time), allowed?(sb),
      record_count, unpack_datetime(current_time), user_info, number,
      delay_time(delaytime), allowed?(tone_set), alrm, temp_unit(tmp_unit),
      temp_calib / 10.0
  end

  def flush
    Termios.tcflush @tty, Termios::TCIOFLUSH
  end

  private

  def temp_unit u
    case u
    when 0x13 then 'F'
    when 0x31 then 'C'
    else
      raise u.to_s
    end
  end

  def delay_time dt
    case dt
    when 0x00 then 0
    when 0x01 then 30 * 60  # 30min in sec
    when 0x10 then 60 * 60  # 60min in sec
    when 0x11 then 90 * 60  # 90min in sec
    when 0x20 then 120 * 60 # 120min in sec
    when 0x21 then 150 * 60 # 150min in sec
    end
  end

  def allowed? sb
    case sb
    when 0x13 then :permit
    when 0x31 then :prohibit
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

  def unpack_datetime bytes
    Time.new(*bytes.unpack('nC5'))
  end

  def with_checksum list
    list + [checksum(list)]
  end

  def checksum list
    list.inject(:+) % 256
  end
end

require 'psych'
temp = Itiscold.open '/dev/tty.wchusbserial1420'
puts Psych.dump temp.device_info
