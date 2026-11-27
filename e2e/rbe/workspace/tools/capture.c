/* Copyright 2026 The OCX Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * capture OUT PROGRAM [ARG...]: runs PROGRAM and writes its stdout to OUT.
 * No shell on the way: this is what lets an action reach a launcher on an executor without /bin/sh.
 * The harness builds it static (`gcc -static`) into tools/capture; it is never committed as a binary. */
#include <fcntl.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 3) return 2;
  int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) { perror("open"); return 2; }
  pid_t pid = fork();
  if (pid < 0) { perror("fork"); return 2; }
  if (pid == 0) {
    dup2(fd, 1);
    close(fd);
    execv(argv[2], argv + 2);
    perror(argv[2]);
    _exit(127);
  }
  int status = 0;
  waitpid(pid, &status, 0);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}
