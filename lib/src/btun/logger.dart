import 'dart:io';

class Logger {
  const Logger();

  void info(String message) => stdout.writeln('[info] $message');
  void warn(String message) => stderr.writeln('[warn] $message');
  void error(String message) => stderr.writeln('[error] $message');
}
