# The hand-written half of the bake definition.
#
# This file holds conventions and nothing else: the build context, the output
# policy, the cache refs, and the groups. Every value that depends on an
# upstream pin -- tags, build args, labels, the base wiring -- is generated
# into bake-targets.json by `ci-images-tool.py bake`, because bake HCL cannot
# compute a variant filter (|short, |dots, |ver), the !qemu_variant helper,
# source_fingerprint() or the semver alias ladder in tag_set(). A pin written
# by hand here would be a pin that can disagree with images.yml, which is the
# one thing this repo's design does not allow.
#
# The two files are merged on the command line:
#
#   docker buildx bake -f bake-targets.json -f docker-bake.hcl <target|group>
#
# rather than read from here, because bake HCL has no file() function. A
# generated JSON file declaring a variable is the supported way to feed data
# in. `ci-images-tool.py build` does all of this for you; the explicit form is
# for inspecting a plan with --print.
#
# Adding an image is still images.yml plus a Dockerfile. Nothing here needs to
# know an image exists: the matrix below forks over whatever TARGETS contains.

# TARGETS and SELECTED are deliberately *not* declared here. They are declared,
# with their values, by the generated bake-targets.json, and a variable block
# in this file would shadow that with its own default -- which renders an empty
# plan rather than an error, so it is worth being explicit about.
#
#   TARGETS   one entry per target: bake_name, dockerfile, tags, args, labels,
#             entitlements, outputs, contexts. See bake_target() in
#             ci-images-tool.py for the shape.
#   SELECTED  the bake_names this run asked for. The generated spec always
#             describes every target, so that --print shows the whole repo
#             whatever is being built; this is how a subset build names its
#             subset.
#
# Neither has a default, so this file cannot be used on its own: without the
# generated JSON alongside it, bake fails rather than quietly building nothing.

# A registry layer cache, e.g. ghcr.io/sbates130272/batesste-ci-images/buildcache.
# Empty disables it. Worth setting for a build on a machine that has never
# built this repo -- a Slurm compute node, most of all, where the daemon is
# per-node and otherwise always cold.
variable "CACHE_REGISTRY" {
  default = ""
}

# Writing the cache back needs a token the read path does not, so it is a
# separate switch rather than implied by CACHE_REGISTRY.
variable "CACHE_TO" {
  default = false
}

# Load the built image into the local daemon. On by default because that is
# what the local build path has always done, and because the per-image checks
# and the artifact push both expect to find the image there. A builder that is
# only producing a registry push can turn it off and save the transfer.
variable "LOAD" {
  default = true
}

target "_common" {
  context = "."
  # The base is either built in this same run (wired through contexts) or
  # named by a tag that moves only when we move it, so re-resolving it on
  # every build buys nothing and costs a registry round trip per target.
  pull = false
}

# One bake target per entry in TARGETS. `name` is what the generated
# bake_name -- the flat scope string, e.g. ubuntu-qcow2-gen-ernic-rocjitsu --
# is for: bake target names may not contain the '@' that every variant key has,
# and bake requires them to be unique across the whole file.
target "image" {
  inherits = ["_common"]

  matrix = {
    t = TARGETS
  }
  name = t.bake_name

  dockerfile = t.dockerfile
  tags       = t.tags
  args       = t.args
  labels     = t.labels

  # Hands one target's output to the next inside a single solve: the key is the
  # ref BASE_IMAGE resolved to, so a derived image layers on the base this run
  # just built without it going through a registry or the local daemon first.
  # Empty when the base is not part of this run.
  contexts = t.contexts

  # security.insecure, for the guest builds that boot QEMU against /dev/kvm.
  # Requesting it here is not the same as being granted it: the invocation
  # still has to pass --allow security.insecure, and the builder still has to
  # have been created with --allow-insecure-entitlement.
  entitlements = t.entitlements

  # type=docker loads the image; t.outputs adds the type=local export that the
  # guest targets use to drop a qcow2 on the host. Both at once is deliberate
  # and is what the old --load plus --output invocation did.
  output = concat(
    LOAD ? ["type=docker"] : [],
    t.outputs,
  )

  cache-from = CACHE_REGISTRY == "" ? [] : [
    "type=registry,ref=${CACHE_REGISTRY}:${t.scope}"
  ]

  # mode=max so the intermediate build stages are cached too, which is most of
  # the win on the multi-stage source builds. image-manifest+oci-mediatypes for
  # GHCR, which rejects the default cache manifest type.
  cache-to = (CACHE_REGISTRY == "" || !CACHE_TO) ? [] : [
    "type=registry,mode=max,image-manifest=true,oci-mediatypes=true,ref=${CACHE_REGISTRY}:${t.scope}"
  ]
}

# The `job:` field in images.yml, as bake groups: `bake bases` builds what
# `targets --job bases` lists. Bases first, then the flat matrix, then the
# images layered on a matrix result.
group "bases" {
  targets = [for t in TARGETS : t.bake_name if t.job == "bases"]
}

group "matrix" {
  targets = [for t in TARGETS : t.bake_name if t.job == "matrix"]
}

group "derived" {
  targets = [for t in TARGETS : t.bake_name if t.job == "derived"]
}

# What the current invocation asked for -- a named target, or everything.
group "selected" {
  targets = SELECTED
}

group "default" {
  targets = [for t in TARGETS : t.bake_name]
}
