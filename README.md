# itiscold

* https://github.com/tenderlove/itiscold

## DESCRIPTION:

A thing that reads data from Elitech RC-5 temp sensor.  Protocol documentation
can be found here:

  https://github.com/civic/elitech-datareader/blob/master/rc-4-data.md

I've tested this on my RC-5, but not an RC-4.

## SYNOPSIS:

Print device information

```ruby
temp = Itiscold.open '/dev/tty.wchusbserial14140'
info = temp.device_info
puts Psych.dump info
```

Set device information (Note that this will clear the memory)

```ruby
# Get the info
temp = Itiscold.open '/dev/tty.wchusbserial14140'
info = temp.device_info

# Mutate it and upload to the device
info.stop_button = :prohibit
temp.device_params = info

# Print info again
info = temp.device_info
puts Psych.dump info
```

Set device time
```ruby
temp = Itiscold.open '/dev/tty.wchusbserial14140'
temp.set_device_time! # defaults to Time.now
```

## INSTALL:

* gem install itiscold
