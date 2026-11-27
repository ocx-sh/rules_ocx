# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for local_binary_request in ocx/private/download.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:download.bzl", "local_binary_request")

_HASH = "a" * 64

def _both_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    r = local_binary_request("", "")
    asserts.equals(env, "", r.url)
    asserts.equals(env, "", r.error)
    return unittest.end(env)

both_empty_test = unittest.make(_both_empty_test_impl)

def _path_without_hash_test_impl(ctx):
    env = unittest.begin(ctx)
    r = local_binary_request("/tmp/ocx", "")
    asserts.true(env, "OCX_INSTALL_BINARY_SHA256" in r.error, r.error)
    asserts.equals(env, "", r.url)
    return unittest.end(env)

path_without_hash_test = unittest.make(_path_without_hash_test_impl)

def _hash_without_path_test_impl(ctx):
    env = unittest.begin(ctx)
    r = local_binary_request("", _HASH)
    asserts.true(env, "OCX_INSTALL_BINARY" in r.error, r.error)
    asserts.equals(env, "", r.url)
    return unittest.end(env)

hash_without_path_test = unittest.make(_hash_without_path_test_impl)

def _bad_hash_test_impl(ctx):
    env = unittest.begin(ctx)
    for bad in ["abc", "A" * 64, "g" * 64, "a" * 65]:
        r = local_binary_request("/tmp/ocx", bad)
        asserts.true(env, "64 lowercase hex" in r.error, "{}: {}".format(bad, r.error))
        asserts.equals(env, "", r.url)
    return unittest.end(env)

bad_hash_test = unittest.make(_bad_hash_test_impl)

def _posix_path_test_impl(ctx):
    env = unittest.begin(ctx)
    r = local_binary_request("/home/u/ocx", _HASH)
    asserts.equals(env, "file:///home/u/ocx", r.url)
    asserts.equals(env, _HASH, r.sha256)
    asserts.equals(env, "", r.error)
    return unittest.end(env)

posix_path_test = unittest.make(_posix_path_test_impl)

def _windows_path_test_impl(ctx):
    env = unittest.begin(ctx)
    r = local_binary_request("C:\\Users\\u\\ocx.exe", _HASH)
    asserts.equals(env, "file:///C:/Users/u/ocx.exe", r.url)
    asserts.equals(env, "", r.error)
    return unittest.end(env)

windows_path_test = unittest.make(_windows_path_test_impl)

def _relative_path_test_impl(ctx):
    env = unittest.begin(ctx)
    r = local_binary_request("bin/ocx", _HASH)
    asserts.true(env, "absolute" in r.error, r.error)
    asserts.equals(env, "", r.url)
    return unittest.end(env)

relative_path_test = unittest.make(_relative_path_test_impl)

def _unsafe_path_test_impl(ctx):
    env = unittest.begin(ctx)
    for bad in ["/tmp/my ocx", "/tmp/50%/ocx", "/tmp/a#b/ocx", "/tmp/a?b/ocx", "C:\\my dir\\ocx.exe"]:
        r = local_binary_request(bad, _HASH)
        asserts.true(env, "must not contain" in r.error, "{}: {}".format(bad, r.error))
        asserts.equals(env, "", r.url)
    return unittest.end(env)

unsafe_path_test = unittest.make(_unsafe_path_test_impl)

def _unc_path_test_impl(ctx):
    env = unittest.begin(ctx)
    for bad in ["\\\\host\\share\\ocx.exe", "//host/share/ocx.exe"]:
        r = local_binary_request(bad, _HASH)
        asserts.true(env, "UNC" in r.error, "{}: {}".format(bad, r.error))
        asserts.equals(env, "", r.url)
    return unittest.end(env)

unc_path_test = unittest.make(_unc_path_test_impl)

def download_test_suite(name):
    """Instantiates the local_binary_request suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        both_empty_test,
        path_without_hash_test,
        hash_without_path_test,
        bad_hash_test,
        posix_path_test,
        windows_path_test,
        relative_path_test,
        unsafe_path_test,
        unc_path_test,
    )
