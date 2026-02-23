from django.shortcuts import render
from django.views.generic import ListView, CreateView, UpdateView, DeleteView
from django.urls import reverse_lazy
from django.http import JsonResponse
from django.core.paginator import Paginator

from apps.cms.models import HomeSlider, ContactForm
from apps.cms.forms import HomeSliderForm


# Create your views here.
class HomeSliderView(ListView):
    model = HomeSlider
    template_name = 'cms/slider.html'

class HomeSliderCreateView(CreateView):
    model = HomeSlider
    form_class = HomeSliderForm
    template_name = 'cms/slider_form.html'
    success_url = reverse_lazy('home_slider')

class HomeSliderUpdateView(UpdateView):
    model = HomeSlider
    form_class = HomeSliderForm
    template_name = 'cms/slider_form.html'
    success_url = reverse_lazy('home_slider')

class HomeSliderDeleteView(DeleteView):
    model = HomeSlider
    template_name = 'cms/slider_confirm_delete.html'
    success_url = reverse_lazy('home_slider')


class ContactFormListView(ListView):
    model = ContactForm
    template_name = 'contacts-data.html'
    context_object_name = 'contacts'
    paginate_by = 20


def contact_form_ajax(request):
    draw = int(request.GET.get('draw', 1))
    start = int(request.GET.get('start', 0))
    length = int(request.GET.get('length', 10))
    search_value = request.GET.get('search[value]', '')

    queryset = ContactForm.objects.all()
    if search_value:
        queryset = queryset.filter(
            name__icontains=search_value
        )

    total = queryset.count()
    paginator = Paginator(queryset, length)
    page_number = start // length + 1
    page = paginator.get_page(page_number)

    data = []
    for contact in page.object_list:
        data.append([
            contact.name,
            contact.email,
            contact.phone,
            contact.subject,
            contact.message,
            contact.created_at.strftime('%Y-%m-%d %H:%M:%S')
        ])

    return JsonResponse({
        'draw': draw,
        'recordsTotal': total,
        'recordsFiltered': total,
        'data': data
    })
