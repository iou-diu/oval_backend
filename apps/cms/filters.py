import django_filters
from apps.cms.models import Catalog
from apps.cms.forms import CatalogFilterForm

class CatalogFilter(django_filters.FilterSet):
    title = django_filters.CharFilter(field_name='title', lookup_expr='icontains')
    class Meta:
        model = Catalog
        fields = ['title', 'is_published', 'is_featured']
        form = CatalogFilterForm
