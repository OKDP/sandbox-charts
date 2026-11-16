// Copyright 2026 The OKDP Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

// Package policytest runs the bootstrap's ValidatingAdmissionPolicies
// (bootstrap/protection/*.yaml) against requests written as fixtures
// (bootstrap/protection/tests/*.yaml), without a cluster: the policies are
// compiled and evaluated by the API server's own admission code
// (k8s.io/apiserver, the CEL environment of the same Kubernetes version as
// the sandbox's), with the matching the API server does before it (the
// policy's matchConstraints and the binding's matchResources, its param).
//
// A fixture names the file of the policies and the policy under test, the
// params (ConfigMaps) of its binding, and cases: a request (operation, user,
// namespace, resource, object, oldObject) and whether it is allowed, with a
// substring of the refusal's message. A request that makes an expression fail
// to evaluate (a CEL error, which the policies' failurePolicy Fail turns into a
// refusal) fails the test unless the case says evalError.
package policytest

import (
	"context"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apiserver/pkg/admission"
	plugincel "k8s.io/apiserver/pkg/admission/plugin/cel"
	"k8s.io/apiserver/pkg/admission/plugin/policy/validating"
	"k8s.io/apiserver/pkg/admission/plugin/webhook/matchconditions"
	celconfig "k8s.io/apiserver/pkg/apis/cel"
	"k8s.io/apiserver/pkg/authentication/user"
	"k8s.io/apiserver/pkg/authorization/authorizer"
	"k8s.io/apiserver/pkg/cel/environment"
	"sigs.k8s.io/yaml"
)

// fixture is a file of bootstrap/protection/tests.
type fixture struct {
	Policies string           `json:"policies"` // the file of the policy and its binding, relative to the fixture
	Policy   string           `json:"policy"`   // the policy under test
	Params   []map[string]any `json:"params"`   // the ConfigMaps the binding's param may name
	// Namespaces is the file of the Namespaces whose labels the requests'
	// namespaces carry, relative to the fixture (bootstrap/namespaces.yaml),
	// for the binding's namespaceSelector.
	Namespaces string     `json:"namespaces"`
	Cases      []testCase `json:"cases"`
}

type testCase struct {
	Name      string   `json:"name"`
	Allow     bool     `json:"allow"`
	Message   string   `json:"message"`   // a substring of the refusal
	EvalError bool     `json:"evalError"` // the refusal is an evaluation error
	Operation string   `json:"operation"`
	User      string   `json:"user"`
	Groups    []string `json:"groups"`
	Namespace string   `json:"namespace"`
	// NamespaceLabels are added to the labels of the request's namespace
	// (a tenant's namespace that carries the platform label, say).
	NamespaceLabels map[string]string `json:"namespaceLabels"`
	Group           string            `json:"group"`
	Resource        string            `json:"resource"`
	Object          map[string]any    `json:"object"`
	OldObject       map[string]any    `json:"oldObject"`
}

// loadObjects reads the YAML documents of path.
func loadObjects(t *testing.T, path string) []map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, doc := range strings.Split("\n"+string(b), "\n---") {
		if strings.TrimSpace(doc) == "" {
			continue
		}
		var m map[string]any
		if err := yaml.Unmarshal([]byte(doc), &m); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if len(m) > 0 {
			out = append(out, m)
		}
	}
	return out
}

func convert[T any](t *testing.T, m map[string]any) *T {
	t.Helper()
	b, err := yaml.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	var v T
	if err := yaml.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return &v
}

// compiled is a policy compiled as the API server does (validating/plugin.go).
type compiled struct {
	validator validating.Validator
	errs      []error
}

func compile(policy *admissionregistrationv1.ValidatingAdmissionPolicy) compiled {
	hasParam := policy.Spec.ParamKind != nil
	optionalVars := plugincel.OptionalVariableDeclarations{HasParams: hasParam, HasAuthorizer: true}
	exprVars := plugincel.OptionalVariableDeclarations{HasParams: hasParam, HasAuthorizer: false}
	failurePolicy := policy.Spec.FailurePolicy
	var errs []error
	compiler, err := plugincel.NewCompositedCompiler(environment.MustBaseEnvSet(environment.DefaultCompatibilityVersion()))
	if err != nil {
		return compiled{validator: validating.NewValidator(nil, nil, nil, nil, failurePolicy, err), errs: []error{err}}
	}
	for _, v := range policy.Spec.Variables {
		if r := compiler.CompileAndStoreVariable(&validating.Variable{Name: v.Name, Expression: v.Expression}, optionalVars, environment.StoredExpressions); r.Error != nil {
			errs = append(errs, fmt.Errorf("variable %s: %w", v.Name, r.Error))
		}
	}
	var matcher matchconditions.Matcher
	if len(policy.Spec.MatchConditions) > 0 {
		acc := make([]plugincel.ExpressionAccessor, len(policy.Spec.MatchConditions))
		for i := range policy.Spec.MatchConditions {
			acc[i] = (*matchconditions.MatchCondition)(&policy.Spec.MatchConditions[i])
		}
		filter := compiler.CompileCondition(acc, optionalVars, environment.StoredExpressions)
		errs = append(errs, filter.CompilationErrors()...)
		matcher = matchconditions.NewMatcher(filter, failurePolicy, "policy", "validate", policy.Name)
	}
	validations := make([]plugincel.ExpressionAccessor, len(policy.Spec.Validations))
	messages := make([]plugincel.ExpressionAccessor, len(policy.Spec.Validations))
	for i, v := range policy.Spec.Validations {
		validations[i] = &validating.ValidationCondition{Expression: v.Expression, Message: v.Message, Reason: v.Reason}
		if v.MessageExpression != "" {
			messages[i] = &validating.MessageExpressionCondition{MessageExpression: v.MessageExpression}
		}
	}
	vf := compiler.CompileCondition(validations, optionalVars, environment.StoredExpressions)
	mf := compiler.CompileCondition(messages, exprVars, environment.StoredExpressions)
	af := compiler.CompileCondition(nil, optionalVars, environment.StoredExpressions)
	errs = append(errs, vf.CompilationErrors()...)
	errs = append(errs, mf.CompilationErrors()...)
	return compiled{validator: validating.NewValidator(vf, matcher, af, mf, failurePolicy, nil), errs: errs}
}

// matches: the resource rules of a policy's matchConstraints.
func matchesRules(rules []admissionregistrationv1.NamedRuleWithOperations, group, resource, op string) bool {
	in := func(list []string, v string) bool {
		for _, e := range list {
			if e == "*" || e == v {
				return true
			}
		}
		return false
	}
	for _, r := range rules {
		ops := make([]string, len(r.Operations))
		for i, o := range r.Operations {
			ops[i] = string(o)
		}
		if in(ops, op) && in(r.APIGroups, group) && in(r.Resources, resource) {
			return true
		}
	}
	return false
}

func selects(sel *metav1.LabelSelector, l map[string]string) (bool, error) {
	if sel == nil {
		return true, nil
	}
	s, err := metav1.LabelSelectorAsSelector(sel)
	if err != nil {
		return false, err
	}
	return s.Matches(labels.Set(l)), nil
}

type denyAll struct{}

func (denyAll) Authorize(context.Context, authorizer.Attributes) (authorizer.Decision, string, error) {
	return authorizer.DecisionDeny, "no authorizer in the policy tests", nil
}

// outcome of one request: refused by which messages, whether one is an evaluation error.
type outcome struct {
	allowed   bool
	messages  []string
	evalError bool
}

func evaluate(t *testing.T, c compiled, policy *admissionregistrationv1.ValidatingAdmissionPolicy, binding *admissionregistrationv1.ValidatingAdmissionPolicyBinding, params []map[string]any, namespaces map[string]map[string]string, tc testCase) outcome {
	t.Helper()
	op := tc.Operation
	obj := tc.Object
	old := tc.OldObject
	// The policy's and the binding's matching.
	if mc := policy.Spec.MatchConstraints; mc != nil {
		if !matchesRules(mc.ResourceRules, tc.Group, tc.Resource, op) {
			return outcome{allowed: true}
		}
		var l map[string]string
		for _, o := range []map[string]any{obj, old} {
			if o != nil {
				l = labelsOf(o)
				break
			}
		}
		ok, err := selects(mc.ObjectSelector, l)
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			return outcome{allowed: true}
		}
	}
	nsLabels := map[string]string{"kubernetes.io/metadata.name": tc.Namespace}
	maps.Copy(nsLabels, namespaces[tc.Namespace])
	maps.Copy(nsLabels, tc.NamespaceLabels)
	nsObj := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: tc.Namespace, Labels: nsLabels}}
	if mr := binding.Spec.MatchResources; mr != nil {
		if mr.NamespaceSelector != nil {
			ok, err := selects(mr.NamespaceSelector, nsObj.Labels)
			if err != nil {
				t.Fatal(err)
			}
			if !ok {
				return outcome{allowed: true}
			}
		}
		if len(mr.ResourceRules) > 0 && !matchesRules(mr.ResourceRules, tc.Group, tc.Resource, op) {
			return outcome{allowed: true}
		}
	}
	// The params.
	var paramObjs []runtime.Object
	if policy.Spec.ParamKind != nil {
		ref := binding.Spec.ParamRef
		if ref == nil {
			t.Fatalf("policy %s has a paramKind and its binding no paramRef", policy.Name)
		}
		ns := ref.Namespace
		if ns == "" {
			ns = tc.Namespace
		}
		for _, p := range params {
			md, _ := p["metadata"].(map[string]any)
			pns, _ := md["namespace"].(string)
			if pns != ns {
				continue
			}
			if ref.Name != "" {
				if n, _ := md["name"].(string); n != ref.Name {
					continue
				}
			} else if ok, err := selects(ref.Selector, labelsOf(p)); err != nil {
				t.Fatal(err)
			} else if !ok {
				continue
			}
			paramObjs = append(paramObjs, &unstructured.Unstructured{Object: p})
		}
		if len(paramObjs) == 0 {
			if ref.ParameterNotFoundAction != nil && *ref.ParameterNotFoundAction == admissionregistrationv1.AllowAction {
				return outcome{allowed: true}
			}
			return outcome{messages: []string{"no param found for the binding"}}
		}
	} else {
		paramObjs = []runtime.Object{nil}
	}
	// The request.
	gvr := schema.GroupVersionResource{Group: tc.Group, Version: "v1", Resource: tc.Resource}
	gvk := schema.GroupVersionKind{Group: tc.Group, Version: "v1", Kind: kindOf(obj, old)}
	var o, oo runtime.Object
	if obj != nil {
		o = &unstructured.Unstructured{Object: obj}
	}
	if old != nil {
		oo = &unstructured.Unstructured{Object: old}
	}
	name := ""
	for _, m := range []map[string]any{obj, old} {
		if m != nil {
			md, _ := m["metadata"].(map[string]any)
			name, _ = md["name"].(string)
			break
		}
	}
	attrs := admission.NewAttributesRecord(o, oo, gvk, tc.Namespace, name, gvr, "", admission.Operation(op), nil, false, &user.DefaultInfo{Name: tc.User, Groups: tc.Groups})
	va := &admission.VersionedAttributes{Attributes: attrs, VersionedKind: gvk, VersionedObject: admission.NewLazyObject(o), VersionedOldObject: admission.NewLazyObject(oo)}
	out := outcome{allowed: true}
	for _, p := range paramObjs {
		res := c.validator.Validate(context.Background(), gvr, va, p, nsObj, celconfig.RuntimeCELCostBudget, denyAll{})
		for _, d := range res.Decisions {
			if d.Action == validating.ActionDeny {
				out.allowed = false
				out.messages = append(out.messages, d.Message)
				if d.Evaluation == validating.EvalError {
					out.evalError = true
				}
			}
		}
	}
	return out
}

func labelsOf(o map[string]any) map[string]string {
	md, _ := o["metadata"].(map[string]any)
	raw, _ := md["labels"].(map[string]any)
	out := map[string]string{}
	for k, v := range raw {
		out[k], _ = v.(string)
	}
	return out
}

func kindOf(objs ...map[string]any) string {
	for _, o := range objs {
		if k, ok := o["kind"].(string); ok {
			return k
		}
	}
	return "Unknown"
}

func TestPolicies(t *testing.T) {
	dir := os.Getenv("POLICY_TESTS")
	if dir == "" {
		dir = filepath.Join("..", "..", "bootstrap", "protection", "tests")
	}
	files, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no fixture in %s (%v)", dir, err)
	}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var fx fixture
		if err := yaml.UnmarshalStrict(raw, &fx); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		var policy *admissionregistrationv1.ValidatingAdmissionPolicy
		var binding *admissionregistrationv1.ValidatingAdmissionPolicyBinding
		for _, o := range loadObjects(t, filepath.Join(filepath.Dir(f), fx.Policies)) {
			switch o["kind"] {
			case "ValidatingAdmissionPolicy":
				if md, _ := o["metadata"].(map[string]any); md["name"] == fx.Policy {
					policy = convert[admissionregistrationv1.ValidatingAdmissionPolicy](t, o)
				}
			case "ValidatingAdmissionPolicyBinding":
				if sp, _ := o["spec"].(map[string]any); sp["policyName"] == fx.Policy {
					binding = convert[admissionregistrationv1.ValidatingAdmissionPolicyBinding](t, o)
				}
			}
		}
		if policy == nil || binding == nil {
			t.Fatalf("%s: policy %s or its binding is not in %s", f, fx.Policy, fx.Policies)
		}
		namespaces := map[string]map[string]string{}
		if fx.Namespaces != "" {
			for _, o := range loadObjects(t, filepath.Join(filepath.Dir(f), fx.Namespaces)) {
				if o["kind"] == "Namespace" {
					md, _ := o["metadata"].(map[string]any)
					name, _ := md["name"].(string)
					namespaces[name] = labelsOf(o)
				}
			}
		}
		c := compile(policy)
		t.Run(fx.Policy+"/compile", func(t *testing.T) {
			for _, e := range c.errs {
				t.Errorf("%v", e)
			}
		})
		for _, tc := range fx.Cases {
			t.Run(fx.Policy+"/"+tc.Name, func(t *testing.T) {
				got := evaluate(t, c, policy, binding, fx.Params, namespaces, tc)
				if got.allowed != tc.Allow {
					t.Fatalf("allowed = %v, want %v (%s)", got.allowed, tc.Allow, strings.Join(got.messages, "; "))
				}
				if got.evalError != tc.EvalError {
					t.Fatalf("evaluation error = %v, want %v (%s)", got.evalError, tc.EvalError, strings.Join(got.messages, "; "))
				}
				if !tc.Allow && tc.Message != "" && !strings.Contains(strings.Join(got.messages, "; "), tc.Message) {
					t.Fatalf("refusal %q does not contain %q", strings.Join(got.messages, "; "), tc.Message)
				}
			})
		}
	}
}
