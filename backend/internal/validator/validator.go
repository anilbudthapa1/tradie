package validator

import (
	"github.com/go-playground/validator/v10"
)

var v = validator.New()

func Validate(s interface{}) map[string]string {
	err := v.Struct(s)
	if err == nil {
		return nil
	}
	errs := make(map[string]string)
	for _, e := range err.(validator.ValidationErrors) {
		errs[e.Field()] = e.Tag()
	}
	return errs
}
