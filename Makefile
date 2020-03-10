STORK_IMG=$(DOCKER_HUB_REPO)/$(DOCKER_HUB_STORK_IMAGE):$(DOCKER_HUB_STORK_TAG)
CMD_EXECUTOR_IMG=$(DOCKER_HUB_REPO)/$(DOCKER_HUB_CMD_EXECUTOR_IMAGE):$(DOCKER_HUB_CMD_EXECUTOR_TAG)
STORK_TEST_IMG=$(DOCKER_HUB_REPO)/$(DOCKER_HUB_STORK_TEST_IMAGE):$(DOCKER_HUB_STORK_TEST_TAG)

ifndef PKGS
# shell does not honor export command above, so we need to explicitly pass GOFLAGS here
PKGS := $(shell GOFLAGS=-mod=vendor go list ./... 2>&1 | grep -v 'github.com/libopenstorage/stork/vendor' | grep -v 'pkg/client/informers/externalversions' | grep -v versioned | grep -v 'pkg/apis/stork')
endif

GO_FILES := $(shell find . -name '*.go' | grep -v vendor | \
                                   grep -v '\.pb\.go' | \
                                   grep -v '\.pb\.gw\.go' | \
                                   grep -v 'externalversions' | \
                                   grep -v 'versioned' | \
                                   grep -v 'generated')

ifeq ($(BUILD_TYPE),debug)
BUILDFLAGS += -gcflags "-N -l"
endif

HAS_GOMODULES := $(shell go help mod why 2> /dev/null)
ifdef HAS_GOMODULES
export GO111MODULE=on
export GOFLAGS= -mod=vendor
else
$(warn vendor import can only be done on  go 1.11+ which supports go modules)
endif

RELEASE_VER := 2.4.0
BASE_DIR    := $(shell git rev-parse --show-toplevel)
GIT_SHA     := $(shell git rev-parse --short HEAD)
BIN         :=$(BASE_DIR)/bin

VERSION = $(RELEASE_VER)-$(GIT_SHA)

LDFLAGS += "-s -w -X github.com/libopenstorage/stork/pkg/version.Version=$(VERSION)"
BUILD_OPTIONS := -ldflags=$(LDFLAGS)

.DEFAULT_GOAL=all
.PHONY: test clean vendor vendor-update vendor-tidy tools

all: stork storkctl cmdexecutor pretest

vendor-update:
	go mod download

vendor:
	go mod vendor
	./hack/update-deprecated-apis.sh

vendor-tidy:
	go mod tidy

fetch-tools:
	( cd tools && \
	GOFLAGS= go get -u golang.org/x/lint/golint && \
	GOFLAGS= go get -u honnef.co/go/tools/cmd/staticcheck && \
	GOFLAGS= go get -u github.com/kisielk/errcheck && \
	GOFLAGS= go get -u github.com/fzipp/gocyclo \
	)

lint:
	for file in $(GO_FILES); do \
		golint $${file}; \
		if [ -n "$$(golint $${file})" ]; then \
			exit 1; \
		fi; \
	done

vet:
	go vet $(PKGS)
	go vet -tags unittest $(PKGS)
	go vet -tags integrationtest github.com/libopenstorage/stork/test/integration_test

staticcheck:
	staticcheck $(PKGS)
	staticcheck -tags integrationtest test/integration_test/*.go
	staticcheck -tags unittest $(PKGS)

errcheck:
	errcheck -verbose -blank $(PKGS)
	errcheck -verbose -blank -tags unittest $(PKGS)
	errcheck -verbose -blank -tags integrationtest github.com/libopenstorage/stork/test/integration_test

check-fmt:
	bash -c "diff -u <(echo -n) <(gofmt -l -d -s -e $(GO_FILES))"

do-fmt:
	 gofmt -s -w $(GO_FILES)

gocyclo:
	gocyclo -over 15 $(GO_FILES)

pretest: fetch-tools check-fmt lint vet errcheck staticcheck

test:
	echo "" > coverage.txt
	for pkg in $(PKGS);	do \
		go test -v -tags unittest -coverprofile=profile.out -covermode=atomic $(BUILD_OPTIONS) $${pkg} || exit 1; \
		if [ -f profile.out ]; then \
			cat profile.out >> coverage.txt; \
			rm profile.out; \
		fi; \
	done

integration-test:
	@echo "Building stork integration tests"
	@cd test/integration_test && go test -tags integrationtest -v -c -o stork.test

integration-test-container:
	@echo "Building container: docker build --tag $(STORK_TEST_IMG) -f Dockerfile ."
	@cd test/integration_test && sudo docker build --tag $(STORK_TEST_IMG) -f Dockerfile .

integration-test-deploy:
	sudo docker push $(STORK_TEST_IMG)

codegen:
	@echo "Generating CRD"
	@hack/update-codegen.sh

stork:
	@echo "Building the stork binary"
	@cd cmd/stork && CGO_ENABLED=0 go build $(BUILD_OPTIONS) -o $(BIN)/stork

cmdexecutor:
	@echo "Building command executor binary"
	@cd cmd/cmdexecutor && go build $(BUILD_OPTIONS) -o $(BIN)/cmdexecutor

storkctl:
	@echo "Building storkctl"
	@cd cmd/storkctl && CGO_ENABLED=0 GOOS=linux go build $(BUILD_OPTIONS) -o $(BIN)/linux/storkctl
	@cd cmd/storkctl && CGO_ENABLED=0 GOOS=darwin go build $(BUILD_OPTIONS) -o $(BIN)/darwin/storkctl
	@cd cmd/storkctl && CGO_ENABLED=0 GOOS=windows go build $(BUILD_OPTIONS) -o $(BIN)/windows/storkctl.exe

container: help
	@echo "Building container: docker build --tag $(STORK_IMG) -f Dockerfile ."
	sudo docker build --tag $(STORK_IMG) -f Dockerfile .

	@echo "Building container: docker build --tag $(CMD_EXECUTOR_IMG) -f Dockerfile.cmdexecutor ."
	sudo docker build --tag $(CMD_EXECUTOR_IMG) -f Dockerfile.cmdexecutor .

help:
	@echo "Updating help file"
	go-md2man -in help.md -out help.1
	go-md2man -in help-cmdexecutor.md -out help-cmdexecutor.1

deploy:
	sudo docker push $(STORK_IMG)
	sudo docker push $(CMD_EXECUTOR_IMG)

clean:
	-rm -rf $(BIN)
	@echo "Deleting image "$(STORK_IMG)
	-sudo docker rmi -f $(STORK_IMG)
	@echo "Deleting image "$(CMD_EXECUTOR_IMG)
	-sudo docker rmi -f $(CMD_EXECUTOR_IMG)
	go clean -i $(PKGS)

