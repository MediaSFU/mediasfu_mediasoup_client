import 'package:flutter/foundation.dart';

abstract class FlexTask {
  final String? id;
  final Function execFun;
  final Function? callbackFun;
  final Function? errorCallbackFun;
  final Object? argument;
  final String? message;

  FlexTask({
    this.id,
    required this.execFun,
    this.argument,
    this.callbackFun,
    this.errorCallbackFun,
    this.message,
  });
}

class FlexTaskAdd extends FlexTask {
  FlexTaskAdd({
    super.id,
    required super.execFun,
    super.argument,
    super.callbackFun,
    super.errorCallbackFun,
    super.message,
  });
}

class FlexTaskRemove extends FlexTask {
  FlexTaskRemove({
    super.id,
    required super.execFun,
    super.argument,
    super.callbackFun,
    super.errorCallbackFun,
    super.message,
  });
}

class FlexQueue {
  bool isBusy = false;
  final List<FlexTask> taskQueue = [];

  void addTask(FlexTask task) async {
    if (task is FlexTaskRemove) {
      final int index =
          taskQueue.indexWhere((FlexTask qTask) => qTask.id == task.id);
      if (index != -1) {
        taskQueue.removeAt(index);
        return;
      } else {
        taskQueue.add(task);
        _runTask();
      }
    } else if (task is FlexTaskAdd) {
      taskQueue.add(task);
      _runTask();
    }
  }

  Future<void> _runTask() async {
    if (!isBusy) {
      if (taskQueue.isNotEmpty) {
        isBusy = true;
        final FlexTask task = taskQueue.removeAt(0);
        try {
          if (task.argument == null) {
            final result = await task.execFun();
            task.callbackFun?.call(result);
          } else {
            final result = await task.execFun(task.argument);
            task.callbackFun?.call(result);
          }
        } catch (error, st) {
          if (kDebugMode) {
            print(error);
          }
          if (kDebugMode) {
            print(st);
          }
          task.errorCallbackFun?.call(error);
        } finally {
          isBusy = false;
          _runTask();
        }
      }
    }
  }
}
